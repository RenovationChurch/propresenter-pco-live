"""ProPresenter Network API client.

Shapes are taken from Renewed Vision's published OpenAPI spec
(https://openapi.propresenter.com):

  GET /v1/playlist/active
    {"presentation": {"playlist": {"uuid", "name", "index"},
                      "item":     {"uuid", "name", "index"}},
     "announcements": {...same...}}
  GET /v1/playlist/{id}
    {"id": {...}, "items": [{"id": {"uuid", "name", "index"},
                             "type": "presentation|placeholder|header|media|audio|livevideo",
                             "is_hidden": bool, "is_pco": bool, ...}]}

An index of 4294967295 (UINT32_MAX) means "nothing" / "not in a playlist".
"""

from __future__ import annotations

from dataclasses import dataclass

import httpx

NO_INDEX = 4294967295


class ProPresenterError(Exception):
    pass


@dataclass(frozen=True)
class PPRef:
    uuid: str
    name: str
    index: int | None


@dataclass(frozen=True)
class PPActive:
    playlist: PPRef | None
    item: PPRef | None


@dataclass(frozen=True)
class PPPlaylistItem:
    uuid: str
    name: str
    index: int | None
    type: str
    is_pco: bool
    is_hidden: bool


class ProPresenterClient:
    def __init__(self, host: str, port: int, *, timeout: float = 2.0, transport: httpx.BaseTransport | None = None):
        self.base_url = f"http://{host}:{port}"
        self._http = httpx.Client(base_url=self.base_url, timeout=timeout, transport=transport)

    def close(self) -> None:
        self._http.close()

    def _get(self, path: str) -> dict:
        try:
            resp = self._http.get(path)
        except httpx.TransportError as exc:
            raise ProPresenterError(f"ProPresenter unreachable at {self.base_url} ({type(exc).__name__})") from None
        if resp.status_code == 404:
            raise ProPresenterError(f"ProPresenter returned 404 for {path} (is Network enabled?)")
        if resp.status_code >= 400:
            raise ProPresenterError(f"ProPresenter {path}: HTTP {resp.status_code}")
        try:
            return resp.json()
        except ValueError:
            raise ProPresenterError(f"ProPresenter {path}: response was not JSON") from None

    def version(self) -> dict:
        return self._get("/version")

    def active(self) -> PPActive:
        doc = self._get("/v1/playlist/active")
        pres = doc.get("presentation") or {}
        return PPActive(playlist=_ref(pres.get("playlist")), item=_ref(pres.get("item")))

    def playlist_items(self, playlist: PPRef) -> list[PPPlaylistItem]:
        key = playlist.uuid or (str(playlist.index) if playlist.index is not None else "")
        if not key:
            raise ProPresenterError("active playlist has no uuid or index")
        doc = self._get(f"/v1/playlist/{key}")
        out = []
        for raw in doc.get("items") or []:
            ref = _ref(raw.get("id"))
            if ref is None:
                continue
            out.append(
                PPPlaylistItem(
                    uuid=ref.uuid,
                    name=ref.name,
                    index=ref.index,
                    type=raw.get("type") or "",
                    is_pco=bool(raw.get("is_pco")),
                    is_hidden=bool(raw.get("is_hidden")),
                )
            )
        return out


def _index(value) -> int | None:
    try:
        i = int(value)
    except (TypeError, ValueError):
        return None
    return None if i == NO_INDEX or i < 0 else i


def _ref(raw) -> PPRef | None:
    if not isinstance(raw, dict):
        return None
    uuid = str(raw.get("uuid") or "")
    name = str(raw.get("name") or "")
    index = _index(raw.get("index"))
    if not uuid and not name and index is None:
        return None
    return PPRef(uuid=uuid, name=name, index=index)
