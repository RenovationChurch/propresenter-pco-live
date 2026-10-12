import httpx

from pcosync.engine import SyncSettings
from tests.conftest import Harness
from tests.fakes import ME, FakeItem, FakePCO, FakePPEntry, FakeProPresenter


def test_normal_progression(harness):
    d = harness.fire("Countdown")
    assert d.action == "moved", d.describe()
    assert harness.live_title == "Countdown"
    assert harness.pco_fake.controller == ME
    for name, title in [("Way Maker", "Way Maker"), ("Goodness Of God", "Goodness of God"), ("Build My Life", "Build My Life")]:
        d = harness.fire(name)
        assert d.action == "moved", d.describe()
        assert harness.live_title == title


def test_refired_cue_never_touches_live(harness):
    harness.pco_fake.place("s1")
    harness.pco_fake.controller = ME
    harness.fire("Way Maker")
    writes_before = len(harness.pco_fake.writes)
    requests_before = len(harness.pco_fake.requests)
    # Re-fire: same item stays active (ProPresenter reports the same item).
    for _ in range(5):
        harness.clock.advance(1.0)
        assert harness.engine.tick().action == "unchanged"
    assert len(harness.pco_fake.writes) == writes_before
    assert len(harness.pco_fake.requests) == requests_before  # not even a read


def test_already_in_sync_does_nothing(harness):
    harness.pco_fake.place("s2")
    harness.pco_fake.controller = ME
    d = harness.fire("Goodness Of God")
    assert d.action == "in_sync"
    assert harness.pco_fake.writes == []


def test_jump_back_lands_on_target(harness):
    harness.pco_fake.place("s3")
    harness.pco_fake.controller = ME
    d = harness.fire("Way Maker")
    assert d.action == "moved", d.describe()
    assert harness.live_title == "Way Maker"
    assert [w[1].rsplit("/", 1)[1] for w in harness.pco_fake.writes] == ["go_to_previous_item"] * 2


def test_skip_ahead_within_limit_and_headers_skipped(harness):
    harness.pco_fake.place("i1")  # Countdown; header WORSHIP sits between
    harness.pco_fake.controller = ME
    d = harness.fire("Goodness Of God")
    assert d.action == "moved", d.describe()
    assert d.steps == 2
    assert harness.live_title == "Goodness of God"


def test_works_when_next_does_not_skip_headers():
    h = Harness(pco=FakePCO(skip_headers=False))
    h.pco_fake.place("i1")
    h.pco_fake.controller = ME
    d = h.fire("Way Maker")
    assert d.action == "moved", d.describe()
    assert h.live_title == "Way Maker"


def test_big_jump_refused_until_confirmed(harness):
    harness.pco_fake.place("i1")
    harness.pco_fake.controller = ME
    d = harness.fire("Doxology")
    assert d.action == "refused"
    assert harness.pco_fake.writes == []
    harness.engine.command("confirm")
    harness.clock.advance(0.5)
    d = harness.engine.tick()
    assert d.action == "moved", d.describe()
    assert harness.live_title == "Doxology"


def test_unmatched_item_never_moves(harness):
    harness.pp_fake.playlist.append(FakePPEntry("Mystery Video", is_pco=False))
    harness.pco_fake.place("s1")
    harness.pco_fake.controller = ME
    d = harness.fire("Mystery Video")
    assert d.action == "skip" and "unmatched" in d.reason
    assert harness.pco_fake.writes == []
    assert harness.live_title == "Way Maker"


def test_ignored_item_never_moves(harness):
    harness.pco_fake.place("s1")
    harness.pco_fake.controller = ME
    d = harness.fire("Pre-Service Loop")
    assert d.action == "skip" and "ignore list" in d.reason
    assert harness.pco_fake.writes == []


def test_dry_run_never_writes():
    h = Harness(armed=False)
    for name in ["Countdown", "Way Maker", "Build My Life", "Sermon"]:
        d = h.fire(name)
        assert d.action in ("dry_run", "refused"), d.describe()
    assert h.pco_fake.writes == []
    assert h.pco_fake.cursor is None


def test_propresenter_unreachable_does_nothing(harness):
    harness.pp_fake.reachable = False
    d = harness.engine.tick()
    assert d.action == "error" and "unreachable" in d.reason
    assert harness.pco_fake.requests[-1][0] == "GET"
    assert harness.pco_fake.writes == []


def test_pco_timeout_on_read_is_error_then_recovers(harness):
    harness.pco_fake.place("s1")
    harness.pco_fake.controller = ME
    harness.pco_fake.fail_queue = [httpx.ReadTimeout("t")] * 10
    d = harness.fire("Goodness Of God")
    assert d.action == "error"
    assert harness.pco_fake.writes == []
    harness.pco_fake.fail_queue = []
    harness.clock.advance(1)
    d = harness.engine.tick()  # error did not mark item handled, so it retries
    assert d.action == "moved", d.describe()


def test_pco_timeout_on_write_is_not_retried(harness):
    harness.pco_fake.place("s1")
    harness.pco_fake.controller = ME
    harness.pp_fake.fire("Goodness Of God")
    harness.engine.tick()
    harness.clock.advance(1.5)
    # live read OK, then the POST times out.
    original = harness.pco_fake.handle
    calls = {"n": 0}

    def flaky(request):
        if request.method == "POST":
            calls["n"] += 1
            raise httpx.ReadTimeout("t")
        return original(request)

    harness.pco_fake.handle = flaky
    harness.pco._http._transport = httpx.MockTransport(flaky)
    d = harness.engine.tick()
    assert d.action == "error"
    assert calls["n"] == 1


def test_rate_limit_429_is_retried(harness):
    harness.pco_fake.place("s1")
    harness.pco_fake.controller = ME
    harness.pp_fake.fire("Goodness Of God")
    harness.engine.tick()
    harness.clock.advance(1.5)
    harness.pco_fake.fail_queue = [429, 429]
    d = harness.engine.tick()
    assert d.action == "moved", d.describe()
    assert harness.sleeps == [1.0, 1.0]


def test_other_controller_is_not_displaced(harness):
    harness.pco_fake.place("s1")
    harness.pco_fake.controller = "555"
    d = harness.fire("Goodness Of God")
    assert d.action == "refused" and "another person" in d.reason
    assert harness.pco_fake.writes == []
    assert harness.pco_fake.controller == "555"


def test_take_over_flag_takes_control():
    h = Harness(settings=SyncSettings(debounce_seconds=1.0, take_over=True, plan_refresh_seconds=0))
    h.pco_fake.place("s1")
    h.pco_fake.controller = "555"
    d = h.fire("Goodness Of God")
    assert d.action == "moved", d.describe()
    assert h.pco_fake.controller == ME


def test_takeover_mid_service_stops_moves(harness):
    harness.fire("Countdown")
    harness.pco_fake.controller = "555"  # a human grabs control
    d = harness.fire("Way Maker")
    assert d.action == "refused"
    assert harness.live_title == "Countdown"


def test_release_only_when_we_hold_control(harness):
    harness.fire("Countdown")
    assert harness.pco_fake.controller == ME
    harness.engine.release()
    assert harness.pco_fake.controller is None
    # If someone else holds it, release must not toggle (that would steal it).
    harness.pco_fake.controller = "555"
    harness.engine.release()
    assert harness.pco_fake.controller == "555"


def test_release_noop_if_we_never_took_control(harness):
    harness.pco_fake.controller = "555"
    harness.engine.release()
    assert harness.pco_fake.writes == []


def test_debounce_ignores_flicker(harness):
    harness.pco_fake.place("s1")
    harness.pco_fake.controller = ME
    harness.fire("Way Maker")
    harness.pp_fake.fire("Doxology")
    assert harness.engine.tick().action == "debounce"
    harness.clock.advance(0.3)
    harness.pp_fake.fire("Way Maker")
    assert harness.engine.tick().action == "debounce"
    harness.clock.advance(2)
    assert harness.engine.tick().action == "unchanged"
    assert harness.pco_fake.writes == []


def test_second_service_time_needs_operator(harness):
    harness.pco_fake.place("s4", "pt9")  # end of 9:00
    harness.pco_fake.controller = ME
    d = harness.fire("Countdown")  # 11:00 begins
    assert d.action == "refused"  # would rewind the 9:00 service
    assert "next-service" in d.reason
    harness.engine.command("next-service")
    harness.clock.advance(0.5)
    d = harness.engine.tick()
    assert d.action == "moved", d.describe()
    assert harness.pco_fake.current()[0] == "pt11"
    assert harness.live_title == "Countdown"
    d = harness.fire("Way Maker")
    assert d.action == "moved"
    assert harness.pco_fake.current() [0] == "pt11"


def test_not_started_live_starts_at_target(harness):
    d = harness.fire("Countdown")
    assert d.action == "moved"
    assert harness.pco_fake.current()[0] == "pt9"


def test_pause_blocks_moves(harness):
    harness.engine.command("pause")
    harness.pp_fake.fire("Countdown")
    harness.clock.advance(5)
    assert harness.engine.tick().action == "paused"
    assert harness.pco_fake.writes == []


def test_playlist_filter():
    h = Harness(settings=SyncSettings(debounce_seconds=1.0, playlist_name_contains="Oct 25", plan_refresh_seconds=0))
    d = h.fire("Countdown")
    assert d.action == "skip" and "doesn't contain" in d.reason


def test_duplicate_titles_resolved_by_occurrence():
    items = [FakeItem("a", "Prayer", "item"), FakeItem("b", "Song A"), FakeItem("c", "Prayer", "item")]
    pl = [FakePPEntry("Prayer"), FakePPEntry("Song A"), FakePPEntry("Prayer")]
    h = Harness(pco=FakePCO(items=items), pp=FakeProPresenter(playlist=pl))
    h.pco_fake.place("b")
    h.pco_fake.controller = ME
    h.pp_fake.active_index = 2
    h.engine.tick()
    h.clock.advance(1.5)
    d = h.engine.tick()
    assert d.action == "moved", d.describe()
    assert h.pco_fake.current()[1].id == "c"


def test_live_parked_on_service_start_slot(harness):
    harness.pco_fake.controller = ME
    harness.pco_fake.cursor = 0  # (pt9, service start)
    d = harness.fire("Countdown")
    assert d.action == "moved", d.describe()
    assert harness.live_title == "Countdown"
    assert len(harness.pco_fake.writes) == 1


def test_works_without_service_start_slots():
    h = Harness(pco=FakePCO(service_markers=False))
    d = h.fire("Countdown")
    assert d.action == "moved", d.describe()
    assert h.live_title == "Countdown"


def test_dry_run_reports_service_start():
    h = Harness(armed=False)
    h.pco_fake.cursor = 0
    d = h.fire("Countdown")
    assert d.action == "dry_run"
    assert "service start 1" in d.describe()


def test_dry_run_simulates_progress():
    h = Harness(armed=False)
    for name in ["Countdown", "Way Maker", "Goodness Of God", "Build My Life", "Welcome and Announcements", "Sermon", "Doxology"]:
        d = h.fire(name)
        assert d.action == "dry_run", d.describe()
        assert d.steps <= 2
    d = h.fire("Way Maker")  # jump back 5 is still refused, as armed would
    assert d.action == "refused"
    assert h.pco_fake.writes == []
