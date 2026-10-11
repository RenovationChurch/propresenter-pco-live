import pytest

from pcosync.engine import SyncEngine, SyncSettings
from pcosync.matcher import MatchSettings
from pcosync.pco import PCOClient
from pcosync.propresenter import ProPresenterClient
from tests.fakes import PLAN, ST, FakePCO, FakeProPresenter

FAKE_APP_ID = "fake-app-id-0123456789"
FAKE_SECRET = "pco_pat_fake_secret_abcdef"


class Clock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t

    def advance(self, s: float) -> None:
        self.t += s


class Harness:
    def __init__(self, armed=True, settings=None, match=None, pco=None, pp=None):
        self.pco_fake = pco or FakePCO()
        self.pp_fake = pp or FakeProPresenter()
        self.clock = Clock()
        self.sleeps: list[float] = []
        self.pco = PCOClient(FAKE_APP_ID, FAKE_SECRET, allow_writes=armed, transport=self.pco_fake.transport(), sleep=self.sleeps.append)
        self.pp = ProPresenterClient("127.0.0.1", 50001, transport=self.pp_fake.transport())
        self.engine = SyncEngine(
            self.pco,
            self.pp,
            service_type_id=ST,
            plan_id=PLAN,
            settings=settings or SyncSettings(debounce_seconds=1.0, max_jump=3, plan_refresh_seconds=0),
            match_settings=match or MatchSettings(ignore=["Pre-Service Loop", "regex:^backup"]),
            armed=armed,
            clock=self.clock,
        )
        self.engine.load_plan()

    def fire(self, name: str):
        """Fire a ProPresenter cue, let debounce elapse, return the acting decision."""
        self.pp_fake.fire(name)
        first = self.engine.tick()
        assert first.action in ("debounce", "unchanged"), first
        self.clock.advance(1.5)
        return self.engine.tick()

    @property
    def live_title(self):
        cur = self.pco_fake.current()
        return cur[1].title if cur and cur[1] else None


@pytest.fixture
def harness():
    return Harness()
