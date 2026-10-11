"""In-memory fakes of the PCO Services API and the ProPresenter API, served
through httpx.MockTransport so the real clients run unchanged.

FakePCO models LIVE as a cursor over (service time, item) slots. Behaviours
that are NOT yet confirmed against real PCO are switchable:
  skip_headers   go_to_next/previous skip header items (assumed True)
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field

import httpx

ST = "111"
PLAN = "222"
ME = "9001"


@dataclass
class FakeItem:
    id: str
    title: str
    item_type: str = "song"


def default_items() -> list[FakeItem]:
    return [
        FakeItem("h1", "PRE-SERVICE", "header"),
        FakeItem("i1", "Countdown", "item"),
        FakeItem("h2", "WORSHIP", "header"),
        FakeItem("s1", "Way Maker"),
        FakeItem("s2", "Goodness of God"),
        FakeItem("s3", "Build My Life"),
        FakeItem("i2", "Welcome & Announcements", "item"),
        FakeItem("i3", "Sermon", "item"),
        FakeItem("s4", "Doxology"),
    ]


@dataclass
class FakePCO:
    items: list[FakeItem] = field(default_factory=default_items)
    plan_times: list[tuple[str, str, str]] = field(
        default_factory=lambda: [("pt9", "service", "2026-10-18T13:00:00Z"), ("pt11", "service", "2026-10-18T15:00:00Z"), ("rh", "rehearsal", "2026-10-18T11:00:00Z")]
    )
    skip_headers: bool = True
    service_markers: bool = True  # a "service start" stop before each service's items
    controller: str | None = None
    cursor: int | None = None  # index into slots, None = not started
    fail_queue: list = field(default_factory=list)  # status codes or exceptions for upcoming requests
    requests: list[tuple[str, str]] = field(default_factory=list)
    secret_seen: str | None = None

    @property
    def slots(self) -> list[tuple[str, FakeItem | None]]:
        pts = [p for p in self.plan_times if p[1] == "service"]
        out = []
        for pt in pts:
            if self.service_markers:
                out.append((pt[0], None))
            out.extend((pt[0], it) for it in self.items)
        return out

    def current(self) -> tuple[str, FakeItem] | None:
        return None if self.cursor is None else self.slots[self.cursor]

    def place(self, item_id: str, plan_time: str = "pt9") -> None:
        self.cursor = next(n for n, (pt, it) in enumerate(self.slots) if pt == plan_time and it and it.id == item_id)

    @property
    def writes(self) -> list[tuple[str, str]]:
        return [r for r in self.requests if r[0] != "GET"]

    def transport(self) -> httpx.MockTransport:
        return httpx.MockTransport(self.handle)

    def _step(self, delta: int) -> None:
        slots = self.slots
        pos = -1 if self.cursor is None else self.cursor
        while True:
            pos += delta
            if pos < 0 or pos >= len(slots):
                return  # at an end: no movement
            item = slots[pos][1]
            if not (self.skip_headers and item is not None and item.item_type == "header"):
                self.cursor = pos
                return

    def handle(self, request: httpx.Request) -> httpx.Response:
        path = request.url.path
        self.requests.append((request.method, path))
        if self.fail_queue:
            failure = self.fail_queue.pop(0)
            if isinstance(failure, Exception):
                raise failure
            headers = {"Retry-After": "1"} if failure == 429 else {}
            return httpx.Response(failure, headers=headers, json={"errors": [{"detail": "fake failure"}]})

        base = f"/services/v2/service_types/{ST}/plans/{PLAN}"
        if path == "/services/v2/me":
            return _json({"data": {"type": "Person", "id": ME}})
        if path == "/services/v2/service_types":
            return _json({"data": [{"type": "ServiceType", "id": ST, "attributes": {"name": "Sunday"}}], "links": {}})
        if path == f"/services/v2/service_types/{ST}/plans":
            return _json({"data": [{"type": "Plan", "id": PLAN, "attributes": {"title": "", "dates": "October 18, 2026"}}], "links": {}})
        if path == base + "/items":
            return self._items_page(request)
        if path == base + "/plan_times":
            data = [{"type": "PlanTime", "id": i, "attributes": {"time_type": t, "starts_at": s, "name": None}} for i, t, s in self.plan_times]
            return _json({"data": data, "links": {}})
        if path == base + "/live" and request.method == "GET":
            return _json(self._live_doc())
        m = re.fullmatch(re.escape(base) + r"/live/(\w+)", path)
        if m and request.method == "POST":
            action = m.group(1)
            if action == "toggle_control":
                self.controller = None if self.controller == ME else ME
            elif action in ("go_to_next_item", "go_to_previous_item"):
                if self.controller != ME:
                    return httpx.Response(403, json={"errors": [{"detail": "not controller"}]})
                self._step(1 if action == "go_to_next_item" else -1)
            else:
                return httpx.Response(404)
            return _json(self._live_doc())
        return httpx.Response(404, json={"errors": [{"detail": f"no fake route {path}"}]})

    def _items_page(self, request: httpx.Request) -> httpx.Response:
        # Two pages to exercise pagination.
        offset = int(request.url.params.get("offset", "0"))
        size = 5
        chunk = self.items[offset : offset + size]
        data = [
            {"type": "Item", "id": it.id, "attributes": {"title": it.title, "item_type": it.item_type, "sequence": offset + n + 1}}
            for n, it in enumerate(chunk)
        ]
        links = {}
        if offset + size < len(self.items):
            links["next"] = str(request.url.copy_with(params={"offset": offset + size}))
        return _json({"data": data, "links": links})

    def _live_doc(self) -> dict:
        cur = self.current()
        rels = {
            "controller": {"data": {"type": "Person", "id": self.controller} if self.controller else None},
            "current_item_time": {"data": {"type": "ItemTime", "id": "it-x"} if cur else None},
        }
        included = []
        if cur:
            included.append(
                {
                    "type": "ItemTime",
                    "id": "it-x",
                    "relationships": {
                        "item": {"data": {"type": "Item", "id": cur[1].id} if cur[1] else None},
                        "plan_time": {"data": {"type": "PlanTime", "id": cur[0]}},
                    },
                }
            )
        if self.controller:
            included.append({"type": "Person", "id": self.controller, "attributes": {}})
        return {"data": {"type": "Live", "id": PLAN, "attributes": {"title": "", "dates": "October 18, 2026"}, "relationships": rels}, "included": included}


@dataclass
class FakePPEntry:
    name: str
    type: str = "presentation"
    is_pco: bool = True
    uuid: str = ""


def default_playlist() -> list[FakePPEntry]:
    return [
        FakePPEntry("PRE-SERVICE", "header"),
        FakePPEntry("Countdown"),
        FakePPEntry("Pre-Service Loop", is_pco=False),
        FakePPEntry("WORSHIP", "header"),
        FakePPEntry("Way Maker"),
        FakePPEntry("Goodness Of God"),
        FakePPEntry("Build My Life"),
        FakePPEntry("Welcome and Announcements"),
        FakePPEntry("Sermon"),
        FakePPEntry("Doxology"),
    ]


@dataclass
class FakeProPresenter:
    playlist: list[FakePPEntry] = field(default_factory=default_playlist)
    playlist_name: str = "Sunday - Oct 18"
    active_index: int | None = None
    reachable: bool = True

    def __post_init__(self):
        for n, e in enumerate(self.playlist):
            e.uuid = e.uuid or f"pp-{n}"

    def fire(self, name: str) -> None:
        self.active_index = next(n for n, e in enumerate(self.playlist) if e.name == name)

    def transport(self) -> httpx.MockTransport:
        return httpx.MockTransport(self.handle)

    def handle(self, request: httpx.Request) -> httpx.Response:
        if not self.reachable:
            raise httpx.ConnectError("connection refused")
        path = request.url.path
        ref_pl = {"uuid": "pl-1", "name": self.playlist_name, "index": 0}
        if path == "/version":
            return _json({"name": "Fake", "platform": "mac", "os_version": "26", "host_description": "ProPresenter 21.0"})
        if path == "/v1/playlist/active":
            if self.active_index is None:
                none = {"uuid": "", "name": "", "index": 4294967295}
                return _json({"presentation": {"playlist": none, "item": none}, "announcements": {"playlist": none, "item": none}})
            e = self.playlist[self.active_index]
            item = {"uuid": e.uuid, "name": e.name, "index": self.active_index}
            return _json({"presentation": {"playlist": ref_pl, "item": item}, "announcements": {"playlist": ref_pl, "item": item}})
        if path in ("/v1/playlist/pl-1", "/v1/playlist/0"):
            items = [
                {"id": {"uuid": e.uuid, "name": e.name, "index": n}, "type": e.type, "is_hidden": False, "is_pco": e.is_pco}
                for n, e in enumerate(self.playlist)
            ]
            return _json({"id": ref_pl, "items": items})
        return httpx.Response(404)


def _json(doc: dict) -> httpx.Response:
    return httpx.Response(200, content=json.dumps(doc).encode(), headers={"Content-Type": "application/json"})
