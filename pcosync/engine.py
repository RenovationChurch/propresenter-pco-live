"""Closed-loop sync: keep LIVE on the PCO item that matches ProPresenter.

Each tick:
  1. Read ProPresenter's active playlist item. Unreachable -> do nothing.
  2. Debounce: the item must stay put for `debounce_seconds`.
  3. If it's the same item we already handled, do nothing (re-firing a cue
     is harmless). Optional periodic resync re-checks anyway.
  4. Match it to a PCO item. Ignored/unmatched -> do nothing, log why.
  5. Read LIVE's current item. Same as target -> do nothing.
  6. Guards: another controller holds LIVE; move larger than `max_jump`.
  7. Dry-run: log what would happen. Armed: take control if needed, then
     step next/previous ONE at a time, re-reading LIVE after every step,
     until LIVE is on the target. Abort on no progress or overshoot.

Positions: LIVE walks through each *service* plan time in order (9:00 items,
then 11:00 items). A position is a slot (plan_time, item) in that global
order. Each service time also has a "service start" slot ahead of its first
item: PCO reports it as an ItemTime whose item is null (seen in the real API
as LIVE's next_item_time before a service begins). The target is the matched item within the "selected" service time,
which follows LIVE's current service time unless the operator overrides it
with the `next-service` / `prev-service` commands or --service-time.
"""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass, field
from typing import Callable

from pcosync.matcher import Matcher, MatchSettings
from pcosync.pco import LiveState, PCOClient, PCOError, PlanItem, PlanTime
from pcosync.propresenter import PPActive, PPPlaylistItem, ProPresenterClient, ProPresenterError

log = logging.getLogger(__name__)


@dataclass
class SyncSettings:
    debounce_seconds: float = 1.0
    max_jump: int = 3
    take_over: bool = False
    resync_seconds: float = 0.0
    plan_refresh_seconds: float = 300.0
    playlist_name_contains: str = ""
    release_on_exit: bool = True


@dataclass
class Decision:
    action: str  # paused|debounce|unchanged|skip|in_sync|dry_run|moved|refused|error
    reason: str = ""
    pp_name: str | None = None
    target: PlanItem | None = None
    live_item: PlanItem | None = None
    steps: int = 0
    live_note: str = ""

    def describe(self) -> str:
        head = ""
        if self.pp_name is not None:
            head = f"ProPresenter '{self.pp_name}'"
        if self.target is not None:
            head += f" -> PCO '{self.target.title}'"
        if self.action in ("in_sync", "dry_run", "moved", "refused") or self.live_item is not None:
            head += f"; LIVE on {self.live_note or _title(self.live_item)}"
        head = head.strip("; ")
        return f"[{self.action}] {head}: {self.reason}" if head else f"[{self.action}] {self.reason}"


def _title(item: PlanItem | None) -> str:
    return f"'{item.title}'" if item else "(not started)"


@dataclass
class _Slot:
    plan_time_id: str | None
    item: PlanItem | None  # None = the service-start slot


@dataclass
class _State:
    candidate_key: tuple | None = None
    candidate_since: float = 0.0
    handled_key: tuple | None = None
    last_check: float = 0.0
    loaded_at: float = 0.0
    selected_pt: int | None = None  # explicit service-time rank, or None = follow LIVE
    confirm_once: bool = False
    paused: bool = False
    took_control: bool = False
    # Dry-run only: (real LIVE slot when simulated, simulated slot). Lets a
    # dry-run behave as if earlier moves had happened.
    simulated: tuple[int, int] | None = None
    playlist_cache: dict = field(default_factory=dict)


class SyncEngine:
    def __init__(
        self,
        pco: PCOClient,
        pp: ProPresenterClient,
        *,
        service_type_id: str,
        plan_id: str,
        settings: SyncSettings | None = None,
        match_settings: MatchSettings | None = None,
        armed: bool = False,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.pco = pco
        self.pp = pp
        self.st = service_type_id
        self.plan = plan_id
        self.settings = settings or SyncSettings()
        self.match_settings = match_settings or MatchSettings()
        self.armed = armed
        self.clock = clock
        self.state = _State()
        self.me: str | None = None
        self.items: list[PlanItem] = []
        self.plan_times: list[PlanTime] = []
        self.matcher = Matcher([], self.match_settings)
        self._slots: list[_Slot] = []
        self._slot_index: dict[tuple, int] = {}
        self._pt_rank: dict[str | None, int] = {}
        self._items_by_id: dict[str, PlanItem] = {}

    # -- plan loading -----------------------------------------------------

    def load_plan(self) -> None:
        self.items = self.pco.plan_items(self.st, self.plan)
        times = [t for t in self.pco.plan_times(self.st, self.plan) if t.time_type == "service"]
        self.plan_times = sorted(times, key=lambda t: t.starts_at or "")
        self.matcher = Matcher(self.items, self.match_settings)
        self._items_by_id = {i.id: i for i in self.items}
        pt_ids: list[str | None] = [t.id for t in self.plan_times] or [None]
        self._pt_rank = {pid: n for n, pid in enumerate(pt_ids)}
        self._slots = []
        for pid in pt_ids:
            self._slots.append(_Slot(pid, None))
            self._slots.extend(_Slot(pid, item) for item in self.items)
        self._slot_index = {(s.plan_time_id, s.item.id if s.item else None): n for n, s in enumerate(self._slots)}
        if self.me is None:
            self.me = self.pco.me_id()
        self.state.loaded_at = self.clock()
        self.state.playlist_cache.clear()
        log.info(
            "Loaded plan %s: %d items (%d headers), %d service time(s)",
            self.plan, len(self.items), sum(i.is_header for i in self.items), len(self.plan_times),
        )

    # -- operator commands ------------------------------------------------

    def command(self, line: str) -> str:
        cmd = line.strip().lower()
        n_pts = max(len(self.plan_times), 1)
        if cmd == "pause":
            self.state.paused = True
            return "Paused: LIVE will not be moved until 'resume'."
        if cmd == "resume":
            self.state.paused = False
            self._force_recheck()
            return "Resumed."
        if cmd == "confirm":
            self.state.confirm_once = True
            self._force_recheck()
            return f"Next move may exceed max_jump={self.settings.max_jump} once."
        if cmd in ("next-service", "prev-service"):
            base = self.state.selected_pt if self.state.selected_pt is not None else self._last_pt_rank
            delta = 1 if cmd == "next-service" else -1
            self.state.selected_pt = min(max(base + delta, 0), n_pts - 1)
            self._force_recheck()
            return f"Targeting service time {self.state.selected_pt + 1} of {n_pts}{self._pt_label(self.state.selected_pt)}."
        if cmd == "auto-service":
            self.state.selected_pt = None
            self._force_recheck()
            return "Service time follows LIVE again."
        if cmd == "reload":
            self.load_plan()
            self._force_recheck()
            return "Plan reloaded."
        if cmd == "status":
            return self.status()
        return "Commands: status, pause, resume, confirm, next-service, prev-service, auto-service, reload, quit"

    def set_service_time(self, one_based: int) -> None:
        self.state.selected_pt = max(0, min(one_based - 1, max(len(self.plan_times), 1) - 1))

    def status(self) -> str:
        sel = self.state.selected_pt
        svc = "follow LIVE" if sel is None else f"{sel + 1}{self._pt_label(sel)}"
        return (
            f"mode={'ARMED' if self.armed else 'dry-run'} paused={self.state.paused} "
            f"service_time={svc} max_jump={self.settings.max_jump} take_over={self.settings.take_over}"
        )

    def _pt_label(self, rank: int) -> str:
        if rank < len(self.plan_times) and self.plan_times[rank].starts_at:
            return f" ({self.plan_times[rank].starts_at})"
        return ""

    def _force_recheck(self) -> None:
        self.state.handled_key = None

    _last_pt_rank: int = 0

    # -- main tick --------------------------------------------------------

    def tick(self) -> Decision:
        now = self.clock()
        if self.state.paused:
            return Decision("paused", "paused by operator")

        if self.settings.plan_refresh_seconds and now - self.state.loaded_at >= self.settings.plan_refresh_seconds:
            try:
                self.load_plan()
            except PCOError as exc:
                log.warning("Plan refresh failed, keeping previous copy: %s", exc)
                self.state.loaded_at = now

        try:
            active = self.pp.active()
        except ProPresenterError as exc:
            return Decision("error", str(exc))

        key = _key(active)
        if key != self.state.candidate_key:
            self.state.candidate_key = key
            self.state.candidate_since = now
        if now - self.state.candidate_since < self.settings.debounce_seconds:
            return Decision("debounce", "waiting for ProPresenter to settle")

        resync_due = self.settings.resync_seconds > 0 and now - self.state.last_check >= self.settings.resync_seconds
        if key == self.state.handled_key and not resync_due:
            return Decision("unchanged", "same ProPresenter item as last time")

        decision = self._evaluate(active)
        if decision.action != "error":
            self.state.handled_key = key
            self.state.last_check = now
        return decision

    def _evaluate(self, active: PPActive) -> Decision:
        item = active.item
        if item is None:
            return Decision("skip", "no active ProPresenter playlist item")
        name = item.name
        filt = self.settings.playlist_name_contains
        pl_name = active.playlist.name if active.playlist else ""
        if filt and filt.casefold() not in pl_name.casefold():
            return Decision("skip", f"active playlist '{pl_name}' doesn't contain '{filt}'", pp_name=name)

        playlist = self._playlist(active)
        result = self.matcher.match(item, playlist)
        if result.item is None:
            return Decision("skip", f"unmatched ({result.reason})", pp_name=name)
        target = result.item

        try:
            live = self.pco.live_state(self.st, self.plan)
        except PCOError as exc:
            return Decision("error", f"PCO unreachable: {exc}", pp_name=name, target=target)

        live_item = self._items_by_id.get(live.current_item_id or "")
        cur = self._position(live)
        note = self._live_note(live, cur)
        tgt = self._target_slot(live, target)
        if tgt is None:
            return Decision("skip", "target item not in loaded plan; try 'reload'", pp_name=name, target=target, live_item=live_item, live_note=note)
        if live.current_item_id is not None and cur is None:
            return Decision("skip", "LIVE is on an item not in the loaded plan; try 'reload'", pp_name=name, target=target, live_item=live_item, live_note=note)
        cur_i = -1 if cur is None else cur
        simulated = ""
        if not self.armed and self.state.simulated and self.state.simulated[0] == cur_i:
            cur_i = self.state.simulated[1]
            simulated = "simulated "
            sim_slot = self._slots[cur_i] if cur_i >= 0 else None
            if sim_slot is not None:
                note = f"{simulated}'{sim_slot.item.title}'" if sim_slot.item else f"{simulated}service start"
                live_item = None
        if cur_i == tgt:
            return Decision("in_sync", f"already there ({result.method})", pp_name=name, target=target, live_item=live_item, live_note=note)

        steps = self._estimate_steps(cur_i, tgt)
        direction = "forward" if tgt > cur_i else "back"
        base = dict(pp_name=name, target=target, live_item=live_item, steps=steps, live_note=note)

        if steps > self.settings.max_jump and not self.state.confirm_once:
            return Decision(
                "refused",
                f"would move {direction} {steps} items (> max_jump {self.settings.max_jump}); "
                "type 'confirm' to allow once, or 'next-service' if a new service time started",
                **base,
            )

        ctrl = self._control_situation(live)
        if ctrl == "other" and not self.settings.take_over:
            return Decision("refused", "another person controls LIVE; not taking over (use --take-over)", **base)

        if not self.armed:
            self.state.simulated = (-1 if cur is None else cur, tgt)
            ctrl_note = {"none": "; would take control", "other": "; would TAKE OVER control"}.get(ctrl, "")
            return Decision("dry_run", f"would move {direction} {steps} item(s) [{result.method}]{ctrl_note}", **base)

        self.state.confirm_once = False
        return self._move(live, cur_i, tgt, ctrl, base)

    # -- writes -----------------------------------------------------------

    def _move(self, live: LiveState, cur: int, tgt: int, ctrl: str, base: dict) -> Decision:
        try:
            if ctrl != "me":
                log.info("Taking LIVE control (%s)", "taking over" if ctrl == "other" else "no current controller")
                self.pco.toggle_control(self.st, self.plan)
                live = self.pco.live_state(self.st, self.plan)
                self.state.took_control = True
                if self._control_situation(live) != "me":
                    return Decision("error", "tried to take LIVE control but don't hold it", **base)

            limit = base["steps"] + 3
            for n in range(limit):
                if tgt > cur:
                    self.pco.go_to_next_item(self.st, self.plan)
                else:
                    self.pco.go_to_previous_item(self.st, self.plan)
                live = self.pco.live_state(self.st, self.plan)
                new = self._position(live)
                new_i = -1 if new is None else new
                base["live_item"] = self._items_by_id.get(live.current_item_id or "")
                base["live_note"] = self._live_note(live, new)
                if new_i == tgt:
                    return Decision("moved", f"moved in {n + 1} step(s)", **base)
                if new_i == cur:
                    return Decision("error", f"LIVE did not move after step {n + 1}; stopping", **base)
                if (tgt - cur) * (tgt - new_i) < 0:
                    return Decision("error", f"LIVE overshot the target after step {n + 1}; stopping", **base)
                cur = new_i
            return Decision("error", f"LIVE not on target after {limit} steps; stopping", **base)
        except PCOError as exc:
            return Decision("error", f"PCO write failed: {exc}", **base)

    def release(self) -> None:
        """Give LIVE control back, only if we hold it. toggle_control is a toggle,
        so calling it when we don't hold control would *take* it."""
        if not (self.armed and self.settings.release_on_exit and self.state.took_control):
            return
        try:
            live = self.pco.live_state(self.st, self.plan)
            if self._control_situation(live) == "me":
                self.pco.toggle_control(self.st, self.plan)
                log.info("Released LIVE control")
            else:
                log.info("Not releasing LIVE control: we no longer hold it")
        except PCOError as exc:
            log.warning("Could not release LIVE control: %s", exc)

    # -- helpers ----------------------------------------------------------

    def _control_situation(self, live: LiveState) -> str:
        if not live.has_controller:
            return "none"
        if live.controller_id is not None and self.me is not None:
            return "me" if live.controller_id == self.me else "other"
        # Controller identity unknown: trust our own record of taking it.
        return "me" if self.state.took_control else "other"

    def _playlist(self, active: PPActive) -> list[PPPlaylistItem] | None:
        if active.playlist is None:
            return None
        key = active.playlist.uuid or active.playlist.index
        cached = self.state.playlist_cache.get(key)
        if cached is not None and _contains(cached, active):
            return cached
        try:
            items = self.pp.playlist_items(active.playlist)
        except ProPresenterError as exc:
            log.warning("Could not read ProPresenter playlist: %s", exc)
            return cached
        self.state.playlist_cache[key] = items
        return items

    def _live_pt(self, live: LiveState) -> int | None:
        return self._pt_rank.get(live.current_plan_time_id) if live.current_plan_time_id in self._pt_rank else None

    def _effective_pt(self, live: LiveState) -> int:
        if self.state.selected_pt is not None:
            return self.state.selected_pt
        live_pt = self._live_pt(live)
        if live_pt is not None:
            self._last_pt_rank = live_pt
            return live_pt
        return self._last_pt_rank

    def _live_note(self, live: LiveState, pos: int | None) -> str:
        if pos is not None and self._slots[pos].item is None:
            return f"service start {self._pt_rank.get(live.current_plan_time_id, 0) + 1}"
        if pos is not None and len(self.plan_times) > 1 and live.current_item_id:
            item = self._items_by_id.get(live.current_item_id)
            return f"'{item.title}' (service {self._pt_rank.get(self._slots[pos].plan_time_id, 0) + 1})" if item else ""
        return ""

    def _pt_id(self, rank: int) -> str | None:
        return self.plan_times[rank].id if self.plan_times else None

    def _position(self, live: LiveState) -> int | None:
        if live.current_item_id is None:
            # Service-start slot if LIVE names a plan time; otherwise LIVE is
            # not started (or has finished).
            if live.current_plan_time_id in self._pt_rank and live.current_plan_time_id is not None:
                return self._slot_index.get((live.current_plan_time_id, None))
            return None
        rank = self._live_pt(live)
        if rank is None:
            rank = self._effective_pt(live)
        return self._slot_index.get((self._pt_id(rank), live.current_item_id))

    def _target_slot(self, live: LiveState, target: PlanItem) -> int | None:
        return self._slot_index.get((self._pt_id(self._effective_pt(live)), target.id))

    def _estimate_steps(self, cur: int, tgt: int) -> int:
        lo, hi = sorted((cur, tgt))
        return sum(1 for s in self._slots[lo + 1 : hi + 1] if s.item is None or not s.item.is_header) or 1


def _key(active: PPActive) -> tuple:
    pl = active.playlist
    it = active.item
    return (
        pl.uuid if pl else None,
        it.uuid if it else None,
        it.index if it else None,
        it.name if it else None,
    )


def _contains(playlist: list[PPPlaylistItem], active: PPActive) -> bool:
    it = active.item
    if it is None:
        return True
    return any((it.uuid and p.uuid == it.uuid) or (p.index == it.index and p.name == it.name) for p in playlist)
