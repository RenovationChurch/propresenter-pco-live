"""Planning Center Services API client (only the parts this tool needs).

Endpoints and LIVE action names used here:
  GET  /services/v2/me
  GET  /services/v2/service_types
  GET  /services/v2/service_types/{st}/plans?filter=future
  GET  /services/v2/service_types/{st}/plans/{plan}/items
  GET  /services/v2/service_types/{st}/plans/{plan}/plan_times
  GET  /services/v2/service_types/{st}/plans/{plan}/live?include=current_item_time,controller
  POST /services/v2/service_types/{st}/plans/{plan}/live/go_to_next_item
  POST /services/v2/service_types/{st}/plans/{plan}/live/go_to_previous_item
  POST /services/v2/service_types/{st}/plans/{plan}/live/toggle_control

The POST action names come from working prior art
(pastorhudson/ProPresenter-PCO-Live-Auto-Control). No "jump to item" action is
known, so the sync engine steps next/previous and re-reads after each step.
See docs/API_NOTES.md for what still needs confirming against the real API.
"""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass
from typing import Any, Callable, Iterator

import httpx

log = logging.getLogger(__name__)

BASE_URL = "https://api.planningcenteronline.com"
MAX_RETRY_AFTER = 30.0


class PCOError(Exception):
    """Any failure talking to Planning Center. Messages never contain secrets."""


class PCOWriteBlocked(PCOError):
    """A write was attempted on a client created without allow_writes."""


@dataclass(frozen=True)
class PlanItem:
    id: str
    title: str
    item_type: str
    sequence: int

    @property
    def is_header(self) -> bool:
        return self.item_type == "header"


@dataclass(frozen=True)
class PlanTime:
    id: str
    time_type: str
    starts_at: str | None
    name: str | None


@dataclass(frozen=True)
class LiveState:
    current_item_id: str | None
    current_plan_time_id: str | None
    controller_id: str | None
    has_controller: bool


class PCOClient:
    def __init__(
        self,
        app_id: str | None,
        secret: str | None,
        *,
        base_url: str = BASE_URL,
        allow_writes: bool = False,
        transport: httpx.BaseTransport | None = None,
        timeout: float = 10.0,
        max_retries: int = 4,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        if not app_id or not secret:
            raise PCOError("Planning Center credentials missing: set PCO_APP_ID and PCO_SECRET")
        self.allow_writes = allow_writes
        self._max_retries = max_retries
        self._sleep = sleep
        self._http = httpx.Client(
            base_url=base_url,
            auth=httpx.BasicAuth(app_id, secret),
            timeout=timeout,
            transport=transport,
            headers={"User-Agent": "propresenter-pco-live (pcosync)"},
        )

    def close(self) -> None:
        self._http.close()

    # -- HTTP plumbing -----------------------------------------------------

    def _request(self, method: str, path: str, params: dict | None = None) -> dict:
        is_write = method != "GET"
        if is_write and not self.allow_writes:
            raise PCOWriteBlocked(f"refusing {method} {path}: client is not armed")
        attempt = 0
        while True:
            attempt += 1
            try:
                resp = self._http.request(method, path, params=params)
            except httpx.TransportError as exc:
                # A write whose outcome is unknown is never retried blindly;
                # the engine re-reads LIVE to find out where it landed.
                if is_write or attempt > self._max_retries:
                    raise PCOError(f"{method} {path}: {type(exc).__name__}") from None
                self._backoff(attempt, f"{type(exc).__name__}")
                continue
            if resp.status_code == 429:
                if attempt > self._max_retries:
                    raise PCOError(f"{method} {path}: rate limited (429) after {attempt} tries")
                wait = _retry_after(resp)
                log.warning("PCO rate limit hit; waiting %.1fs", wait)
                self._sleep(wait)
                continue
            if resp.status_code >= 500:
                if is_write or attempt > self._max_retries:
                    raise PCOError(f"{method} {path}: server error {resp.status_code}")
                self._backoff(attempt, f"HTTP {resp.status_code}")
                continue
            if resp.status_code == 401:
                raise PCOError("Planning Center rejected the credentials (401). Check PCO_APP_ID / PCO_SECRET.")
            if resp.status_code == 403:
                raise PCOError(f"{method} {path}: forbidden (403). Does this PCO user have LIVE control permission?")
            if resp.status_code >= 400:
                raise PCOError(f"{method} {path}: HTTP {resp.status_code} {_error_detail(resp)}")
            if not resp.content:
                return {}
            return resp.json()

    def _backoff(self, attempt: int, why: str) -> None:
        wait = min(2 ** (attempt - 1), 8)
        log.warning("PCO request failed (%s); retrying in %ss", why, wait)
        self._sleep(wait)

    def get(self, path: str, params: dict | None = None) -> dict:
        return self._request("GET", path, params)

    def post(self, path: str) -> dict:
        return self._request("POST", path)

    def paginate(self, path: str, params: dict | None = None) -> Iterator[dict]:
        params = {"per_page": 100, **(params or {})}
        doc = self.get(path, params)
        while True:
            yield from doc.get("data", [])
            nxt = (doc.get("links") or {}).get("next")
            if not nxt:
                return
            doc = self.get(nxt)

    # -- Read-only helpers -------------------------------------------------

    def me_id(self) -> str | None:
        for path in ("/services/v2/me", "/people/v2/me"):
            try:
                return str(self.get(path)["data"]["id"])
            except (PCOError, KeyError, TypeError) as exc:
                log.debug("could not read %s: %s", path, exc)
        return None

    def service_types(self) -> list[tuple[str, str]]:
        return [(d["id"], d["attributes"].get("name") or "") for d in self.paginate("/services/v2/service_types")]

    def future_plans(self, service_type_id: str) -> list[dict]:
        out = []
        for d in self.paginate(f"/services/v2/service_types/{service_type_id}/plans", {"filter": "future", "order": "sort_date"}):
            a = d.get("attributes", {})
            out.append({"id": d["id"], "title": a.get("title") or "", "dates": a.get("dates") or ""})
        return out

    def resolve_plan_id(self, service_type_id: str, plan: str) -> str:
        if plan != "next":
            return plan
        plans = self.future_plans(service_type_id)
        if not plans:
            raise PCOError(f"no future plans in service type {service_type_id}")
        return plans[0]["id"]

    def _plan_path(self, service_type_id: str, plan_id: str) -> str:
        return f"/services/v2/service_types/{service_type_id}/plans/{plan_id}"

    def plan_items(self, service_type_id: str, plan_id: str) -> list[PlanItem]:
        items = [
            PlanItem(
                id=str(d["id"]),
                title=d["attributes"].get("title") or "",
                item_type=d["attributes"].get("item_type") or "item",
                sequence=int(d["attributes"].get("sequence") or 0),
            )
            for d in self.paginate(self._plan_path(service_type_id, plan_id) + "/items")
        ]
        return sorted(items, key=lambda i: i.sequence)

    def plan_times(self, service_type_id: str, plan_id: str) -> list[PlanTime]:
        return [
            PlanTime(
                id=str(d["id"]),
                time_type=d["attributes"].get("time_type") or "",
                starts_at=d["attributes"].get("starts_at"),
                name=d["attributes"].get("name"),
            )
            for d in self.paginate(self._plan_path(service_type_id, plan_id) + "/plan_times")
        ]

    def live_state(self, service_type_id: str, plan_id: str) -> LiveState:
        doc = self.get(
            self._plan_path(service_type_id, plan_id) + "/live",
            {"include": "current_item_time,controller"},
        )
        return parse_live(doc)

    # -- LIVE writes (only when armed) ------------------------------------

    def go_to_next_item(self, service_type_id: str, plan_id: str) -> None:
        self.post(self._plan_path(service_type_id, plan_id) + "/live/go_to_next_item")

    def go_to_previous_item(self, service_type_id: str, plan_id: str) -> None:
        self.post(self._plan_path(service_type_id, plan_id) + "/live/go_to_previous_item")

    def toggle_control(self, service_type_id: str, plan_id: str) -> None:
        self.post(self._plan_path(service_type_id, plan_id) + "/live/toggle_control")


def parse_live(doc: dict) -> LiveState:
    data = doc.get("data") or {}
    rels = data.get("relationships") or {}
    included = doc.get("included") or []

    ctrl = _rel_data(rels, "controller")
    controller_id = str(ctrl["id"]) if ctrl else None
    has_controller = controller_id is not None or bool((data.get("links") or {}).get("controller"))

    item_times = [inc for inc in included if inc.get("type") == "ItemTime"]
    cur = _rel_data(rels, "current_item_time")
    item_time = None
    if cur:
        item_time = next((it for it in item_times if str(it.get("id")) == str(cur.get("id"))), None)
    elif len(item_times) == 1 and "current_item_time" not in rels:
        item_time = item_times[0]

    item_id = plan_time_id = None
    if item_time:
        it_rels = item_time.get("relationships") or {}
        item = _rel_data(it_rels, "item")
        pt = _rel_data(it_rels, "plan_time")
        item_id = str(item["id"]) if item else None
        plan_time_id = str(pt["id"]) if pt else None
    return LiveState(item_id, plan_time_id, controller_id, has_controller)


def _rel_data(rels: dict, name: str) -> dict | None:
    rel = rels.get(name)
    if isinstance(rel, dict):
        data = rel.get("data")
        if isinstance(data, dict):
            return data
    return None


def _retry_after(resp: httpx.Response) -> float:
    try:
        return max(0.5, min(float(resp.headers.get("Retry-After", "")), MAX_RETRY_AFTER))
    except ValueError:
        return 5.0


def _error_detail(resp: httpx.Response) -> str:
    try:
        errors: Any = resp.json().get("errors") or []
        return "; ".join(str(e.get("detail") or e.get("title") or "") for e in errors)[:300]
    except Exception:
        return ""
