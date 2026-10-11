"""Config: TOML file (git-ignored config.toml) plus env vars for secrets."""

from __future__ import annotations

import os
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

from pcosync.engine import SyncSettings
from pcosync.matcher import MatchSettings
from pcosync.pco import BASE_URL


@dataclass
class Config:
    app_id: str | None = None
    secret: str | None = field(default=None, repr=False)
    service_type_id: str = ""
    pco_base_url: str = BASE_URL
    plan: str = "next"
    pp_host: str = "127.0.0.1"
    pp_port: int = 50001
    pp_timeout: float = 2.0
    poll_interval: float = 0.5
    sync: SyncSettings = field(default_factory=SyncSettings)
    match: MatchSettings = field(default_factory=MatchSettings)
    log_file: str = "logs/pcosync.log"
    log_level: str = "INFO"

    @property
    def secrets(self) -> list[str]:
        return [s for s in (self.app_id, self.secret) if s]


def load_config(path: str | os.PathLike | None) -> Config:
    raw: dict = {}
    if path is not None:
        p = Path(path)
        if p.exists():
            with p.open("rb") as f:
                raw = tomllib.load(f)
        elif str(path) != "config.toml":
            raise FileNotFoundError(f"config file not found: {p}")

    pco = raw.get("pco", {})
    pp = raw.get("propresenter", {})
    sync = raw.get("sync", {})
    match = raw.get("match", {})
    logging_ = raw.get("logging", {})

    cfg = Config(
        app_id=os.environ.get("PCO_APP_ID") or pco.get("app_id"),
        secret=os.environ.get("PCO_SECRET") or pco.get("secret"),
        service_type_id=str(pco.get("service_type_id", "") or ""),
        # Only for pointing at tools/mock_servers.py during development.
        pco_base_url=os.environ.get("PCO_BASE_URL") or BASE_URL,
        plan=str(pco.get("plan", "next") or "next"),
        pp_host=str(pp.get("host", "127.0.0.1")),
        pp_port=int(pp.get("port", 50001)),
        pp_timeout=float(pp.get("timeout", 2.0)),
        poll_interval=float(pp.get("poll_interval", 0.5)),
        log_file=str(logging_.get("file", "logs/pcosync.log")),
        log_level=str(logging_.get("level", "INFO")).upper(),
    )
    cfg.sync = SyncSettings(
        debounce_seconds=float(sync.get("debounce_seconds", 1.0)),
        max_jump=int(sync.get("max_jump", 3)),
        take_over=bool(sync.get("take_over", False)),
        resync_seconds=float(sync.get("resync_seconds", 0.0)),
        plan_refresh_seconds=float(sync.get("plan_refresh_seconds", 300.0)),
        playlist_name_contains=str(pp.get("playlist_name_contains", "") or ""),
        release_on_exit=bool(sync.get("release_on_exit", True)),
    )
    cfg.match = MatchSettings(
        ignore=[str(x) for x in match.get("ignore", [])],
        aliases={str(k): str(v) for k, v in (match.get("aliases") or {}).items()},
        positional_fallback=bool(match.get("positional_fallback", True)),
    )
    return cfg
