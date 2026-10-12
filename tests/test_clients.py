import logging

import httpx
import pytest

from pcosync.log import RedactSecrets
from pcosync.pco import PCOClient, PCOError, PCOWriteBlocked, parse_live
from pcosync.propresenter import ProPresenterClient
from tests.conftest import FAKE_APP_ID, FAKE_SECRET, Harness
from tests.fakes import ME, PLAN, ST, FakePCO, FakeProPresenter


def test_unarmed_client_cannot_write():
    fake = FakePCO()
    pco = PCOClient(FAKE_APP_ID, FAKE_SECRET, transport=fake.transport())
    with pytest.raises(PCOWriteBlocked):
        pco.go_to_next_item(ST, PLAN)
    assert fake.requests == []


def test_missing_credentials():
    with pytest.raises(PCOError):
        PCOClient(None, "x")


def test_401_message_has_no_secret():
    pco = PCOClient(FAKE_APP_ID, FAKE_SECRET, transport=httpx.MockTransport(lambda r: httpx.Response(401)))
    with pytest.raises(PCOError) as exc:
        pco.service_types()
    assert FAKE_SECRET not in str(exc.value) and FAKE_APP_ID not in str(exc.value)


def test_pagination_reads_all_items():
    fake = FakePCO()
    pco = PCOClient(FAKE_APP_ID, FAKE_SECRET, transport=fake.transport())
    items = pco.plan_items(ST, PLAN)
    assert [i.id for i in items] == [i.id for i in fake.items]


def test_live_state_parse():
    fake = FakePCO()
    fake.place("s2", "pt11")
    fake.controller = ME
    pco = PCOClient(FAKE_APP_ID, FAKE_SECRET, transport=fake.transport())
    live = pco.live_state(ST, PLAN)
    assert (live.current_item_id, live.current_plan_time_id, live.controller_id, live.has_controller) == ("s2", "pt11", ME, True)


def test_live_parse_link_only_controller_and_not_started():
    live = parse_live({"data": {"links": {"controller": "https://x/people/1"}, "relationships": {}}, "included": []})
    assert live.has_controller and live.controller_id is None and live.current_item_id is None


def test_propresenter_active_none_index():
    pp = ProPresenterClient("h", 1, transport=FakeProPresenter().transport())
    active = pp.active()
    assert active.item is None and active.playlist is None


def test_propresenter_active_and_playlist():
    fake = FakeProPresenter()
    fake.fire("Way Maker")
    pp = ProPresenterClient("h", 1, transport=fake.transport())
    active = pp.active()
    assert active.item.name == "Way Maker" and active.item.index == 4
    items = pp.playlist_items(active.playlist)
    assert items[0].type == "header" and items[2].is_pco is False


def test_redaction_filter(caplog):
    logger = logging.getLogger("redact-test")
    logger.addFilter(RedactSecrets([FAKE_SECRET]))
    with caplog.at_level(logging.INFO, logger="redact-test"):
        logger.info("token is %s", FAKE_SECRET)
    assert FAKE_SECRET not in caplog.text and "***" in caplog.text


def test_secrets_never_logged_during_sync(caplog):
    with caplog.at_level(logging.DEBUG):
        h = Harness()
        h.fire("Countdown")
        h.fire("Way Maker")
        h.engine.release()
    assert FAKE_SECRET not in caplog.text
    assert FAKE_APP_ID not in caplog.text


def test_parse_real_service_start_item_time():
    # Shape captured from the real API (next_item_time before a service starts).
    doc = {
        "data": {
            "type": "Live",
            "links": {"controller": None, "current_item_time": None},
            "relationships": {"current_item_time": {"data": {"type": "ItemTime", "id": "224515872"}}, "controller": {"data": None}},
        },
        "included": [
            {
                "type": "ItemTime",
                "id": "224515872",
                "attributes": {"exclude": False, "length": 7870.0, "live_end_at": None, "live_start_at": None},
                "relationships": {
                    "item": {"data": None},
                    "plan_time": {"data": {"type": "PlanTime", "id": "224515872"}},
                    "plan": {"data": {"type": "Plan", "id": "90700203"}},
                },
            }
        ],
    }
    live = parse_live(doc)
    assert live.current_item_id is None
    assert live.current_plan_time_id == "224515872"
    assert not live.has_controller
