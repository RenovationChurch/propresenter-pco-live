"""Command line entry point: python -m pcosync <command> ..."""

from __future__ import annotations

import argparse
import logging
import queue
import signal
import sys
import threading
import time

from pcosync.config import Config, load_config
from pcosync.engine import SyncEngine
from pcosync.log import setup_logging
from pcosync.matcher import Matcher
from pcosync.pco import PCOClient, PCOError
from pcosync.propresenter import PPRef, ProPresenterClient, ProPresenterError

log = logging.getLogger("pcosync")

QUIET_ACTIONS = {"debounce", "unchanged", "paused"}


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="pcosync", description="Keep PCO Services LIVE on the same item as ProPresenter.")
    p.add_argument("--config", default="config.toml", help="path to config TOML (default: config.toml)")
    p.add_argument("--service-type", help="PCO service type ID (overrides config)")
    p.add_argument("--plan", help="PCO plan ID or 'next' (overrides config)")
    p.add_argument("-v", "--verbose", action="store_true", help="debug logging")
    sub = p.add_subparsers(dest="command", required=True)

    sub.add_parser("test-connection", help="check ProPresenter and PCO connectivity (read-only)")
    sub.add_parser("service-types", help="list PCO service types (read-only)")
    sub.add_parser("plans", help="list upcoming plans for the service type (read-only)")
    sub.add_parser("items", help="list the plan's items (read-only)")
    sub.add_parser("live", help="show LIVE's current item and controller (read-only)")
    sub.add_parser("mapping", help="show how each ProPresenter playlist item maps to PCO (read-only)")

    run = sub.add_parser("run", help="watch ProPresenter and sync LIVE (dry-run unless --armed)")
    run.add_argument("--armed", action="store_true", help="actually move LIVE. Without this, nothing is written.")
    run.add_argument("--take-over", action="store_true", help="take LIVE control even if someone else holds it")
    run.add_argument("--max-jump", type=int, help="refuse moves larger than this many items unless confirmed")
    run.add_argument("--service-time", type=int, help="target service time N (1-based) instead of following LIVE")
    run.add_argument("--debounce", type=float, help="seconds ProPresenter must stay on an item before syncing")
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        cfg = load_config(args.config)
    except (OSError, ValueError) as exc:
        print(f"config error: {exc}", file=sys.stderr)
        return 2
    if args.service_type:
        cfg.service_type_id = args.service_type
    if args.plan:
        cfg.plan = args.plan
    setup_logging("DEBUG" if args.verbose else cfg.log_level, cfg.log_file if args.command == "run" else None, cfg.secrets)

    try:
        return COMMANDS[args.command](cfg, args)
    except (PCOError, ProPresenterError) as exc:
        log.error("%s", exc)
        return 1


# -- read-only commands ----------------------------------------------------


def _pco(cfg: Config, armed: bool = False) -> PCOClient:
    return PCOClient(cfg.app_id, cfg.secret, base_url=cfg.pco_base_url, allow_writes=armed)


def _pp(cfg: Config) -> ProPresenterClient:
    return ProPresenterClient(cfg.pp_host, cfg.pp_port, timeout=cfg.pp_timeout)


def _need_service_type(cfg: Config) -> str:
    if not cfg.service_type_id:
        raise PCOError("no service type: pass --service-type ID or set pco.service_type_id (see 'service-types')")
    return cfg.service_type_id


def cmd_test_connection(cfg: Config, args) -> int:
    ok = True
    pp = _pp(cfg)
    try:
        ver = pp.version()
        print(f"ProPresenter OK at {pp.base_url}: {ver}")
        active = pp.active()
        print(f"  active playlist: {active.playlist.name if active.playlist else '(none)'}")
        print(f"  active item:     {active.item.name if active.item else '(none)'}")
    except ProPresenterError as exc:
        ok = False
        print(f"ProPresenter FAILED: {exc}")
    try:
        pco = _pco(cfg)
        me = pco.me_id()
        types = pco.service_types()
        print(f"Planning Center OK: person id {me or '(unknown)'}; {len(types)} service type(s)")
    except PCOError as exc:
        ok = False
        print(f"Planning Center FAILED: {exc}")
    return 0 if ok else 1


def cmd_service_types(cfg: Config, args) -> int:
    for sid, name in _pco(cfg).service_types():
        print(f"{sid:>10}  {name}")
    return 0


def cmd_plans(cfg: Config, args) -> int:
    for plan in _pco(cfg).future_plans(_need_service_type(cfg)):
        print(f"{plan['id']:>10}  {plan['dates']:<24} {plan['title']}")
    return 0


def cmd_items(cfg: Config, args) -> int:
    pco = _pco(cfg)
    st = _need_service_type(cfg)
    plan = pco.resolve_plan_id(st, cfg.plan)
    print(f"Plan {plan}")
    for item in pco.plan_items(st, plan):
        print(f"{item.sequence:>4}  {item.item_type:<8} {item.id:>10}  {item.title}")
    for t in pco.plan_times(st, plan):
        print(f"time {t.id:>10}  {t.time_type:<10} {t.starts_at or ''}  {t.name or ''}")
    return 0


def cmd_live(cfg: Config, args) -> int:
    pco = _pco(cfg)
    st = _need_service_type(cfg)
    plan = pco.resolve_plan_id(st, cfg.plan)
    items = {i.id: i for i in pco.plan_items(st, plan)}
    live = pco.live_state(st, plan)
    me = pco.me_id()
    cur = items.get(live.current_item_id or "")
    print(f"Plan {plan}")
    print(f"  current item: {cur.title if cur else '(not started / unknown)'} (item {live.current_item_id})")
    print(f"  plan time:    {live.current_plan_time_id}")
    who = "nobody" if not live.has_controller else ("you" if live.controller_id and live.controller_id == me else f"person {live.controller_id or '(unknown)'}")
    print(f"  controller:   {who}")
    return 0


def cmd_mapping(cfg: Config, args) -> int:
    pco = _pco(cfg)
    pp = _pp(cfg)
    st = _need_service_type(cfg)
    plan = pco.resolve_plan_id(st, cfg.plan)
    matcher = Matcher(pco.plan_items(st, plan), cfg.match)
    active = pp.active()
    if active.playlist is None:
        print("ProPresenter has no active playlist. Click an item in the service playlist first.")
        return 1
    playlist = pp.playlist_items(active.playlist)
    print(f"ProPresenter playlist '{active.playlist.name}' -> PCO plan {plan}\n")
    for entry in playlist:
        res = matcher.match(PPRef(entry.uuid, entry.name, entry.index), playlist)
        target = f"'{res.item.title}' (#{res.item.sequence})" if res.item else "-- no move --"
        flag = "pco" if entry.is_pco else "   "
        print(f"{entry.index if entry.index is not None else '?':>3} {flag} {entry.type:<12} {entry.name[:40]:<40} -> {target}  [{res.method}: {res.reason}]")
    return 0


# -- run loop --------------------------------------------------------------


def cmd_run(cfg: Config, args) -> int:
    if args.max_jump is not None:
        cfg.sync.max_jump = args.max_jump
    if args.debounce is not None:
        cfg.sync.debounce_seconds = args.debounce
    if args.take_over:
        cfg.sync.take_over = True

    pco = _pco(cfg, armed=args.armed)
    st = _need_service_type(cfg)
    plan = pco.resolve_plan_id(st, cfg.plan)
    engine = SyncEngine(
        pco, _pp(cfg), service_type_id=st, plan_id=plan, settings=cfg.sync, match_settings=cfg.match, armed=args.armed
    )
    engine.load_plan()
    if args.service_time:
        engine.set_service_time(args.service_time)

    if args.armed:
        log.warning("ARMED: this will take LIVE control and move LIVE for plan %s. A human controller will be displaced.", plan)
        log.warning("Reset rehearsal times in LIVE before the real service.")
    else:
        log.info("DRY-RUN: nothing will be written to Planning Center. Use --armed to move LIVE.")
    log.info("Type 'help' + Enter for commands. Ctrl-C to stop.")
    log.info("%s", engine.status())

    commands: queue.Queue[str] = queue.Queue()
    if sys.stdin and sys.stdin.isatty():
        threading.Thread(target=_read_stdin, args=(commands,), daemon=True).start()

    stop = threading.Event()

    def _stop(signum, frame):
        stop.set()

    signal.signal(signal.SIGTERM, _stop)

    last_shown = None
    backoff = 0.0
    try:
        while not stop.is_set():
            while not commands.empty():
                line = commands.get_nowait()
                if line.strip().lower() in ("quit", "exit", "q"):
                    stop.set()
                    break
                log.info("%s", engine.command(line))
            if stop.is_set():
                break

            decision = engine.tick()
            shown = (decision.action, decision.reason, decision.pp_name)
            if decision.action in QUIET_ACTIONS:
                log.debug("%s", decision.describe())
            elif shown != last_shown or decision.action in ("moved", "dry_run"):
                level = logging.WARNING if decision.action in ("error", "refused") else logging.INFO
                log.log(level, "%s", decision.describe())
            last_shown = shown if decision.action not in QUIET_ACTIONS else last_shown

            if decision.action == "error":
                backoff = min(max(backoff * 2, 1.0), 30.0)
                stop.wait(backoff)
            else:
                backoff = 0.0
                stop.wait(cfg.poll_interval)
    except KeyboardInterrupt:
        pass
    finally:
        log.info("Stopping")
        engine.release()
        pco.close()
    return 0


def _read_stdin(q: queue.Queue) -> None:
    for line in sys.stdin:
        q.put(line)


COMMANDS = {
    "test-connection": cmd_test_connection,
    "service-types": cmd_service_types,
    "plans": cmd_plans,
    "items": cmd_items,
    "live": cmd_live,
    "mapping": cmd_mapping,
    "run": cmd_run,
}
