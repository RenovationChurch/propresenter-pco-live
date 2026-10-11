from pcosync.matcher import Matcher, MatchSettings, normalize
from pcosync.pco import PlanItem
from pcosync.propresenter import PPPlaylistItem, PPRef

ITEMS = [
    PlanItem("h", "WORSHIP", "header", 1),
    PlanItem("1", "Way Maker", "song", 2),
    PlanItem("2", "Goodness of God", "song", 3),
    PlanItem("3", "Welcome & Announcements", "item", 4),
]


def ref(name, uuid="", index=None):
    return PPRef(uuid, name, index)


def entry(name, index, type_="presentation", is_pco=True):
    return PPPlaylistItem(f"u{index}", name, index, type_, is_pco, False)


def test_normalize():
    assert normalize("  Goodness Of God! ") == "goodness of god"
    assert normalize("Welcome & Announcements") == normalize("welcome and announcements")
    assert normalize("Who You Say I’m") == normalize("Who You Say Im")
    assert normalize("Él Shaddai") == "el shaddai"


def test_title_match():
    m = Matcher(ITEMS)
    r = m.match(ref("goodness of GOD"))
    assert r.item.id == "2" and r.method == "title"


def test_headers_never_match_by_title():
    assert Matcher(ITEMS).match(ref("Worship")).item is None


def test_alias():
    m = Matcher(ITEMS, MatchSettings(aliases={"Way Maker (Live)": "Way Maker"}))
    r = m.match(ref("Way Maker (live)"))
    assert r.item.id == "1" and r.method == "alias"


def test_ignore_exact_and_regex():
    m = Matcher(ITEMS, MatchSettings(ignore=["Way Maker", "regex:^backup"]))
    assert m.match(ref("way maker")).method == "ignored"
    assert m.match(ref("BACKUP slides")).method == "ignored"


def test_positional_fallback_uses_is_pco_entries_only():
    playlist = [
        entry("WORSHIP", 0, "header"),
        entry("Loop", 1, is_pco=False),
        entry("WM - Key of B", 2),
        entry("GOG", 3),
        entry("Welcome", 4),
    ]
    m = Matcher(ITEMS)
    r = m.match(ref("GOG", "u3", 3), playlist)
    assert r.item.id == "2" and r.method == "position"
    assert m.match(ref("Loop", "u1", 1), playlist).item is None


def test_positional_fallback_disabled():
    playlist = [entry("WORSHIP", 0, "header"), entry("WM", 1), entry("GOG", 2), entry("Welcome", 3)]
    m = Matcher(ITEMS, MatchSettings(positional_fallback=False))
    assert m.match(ref("GOG", "u2", 2), playlist).item is None


def test_positional_requires_equal_counts():
    playlist = [entry("WM", 0), entry("GOG", 1)]
    assert Matcher(ITEMS).match(ref("GOG", "u1", 1), playlist).item is None


def test_pp_header_never_matches():
    playlist = [entry("Way Maker", 0, "header")]
    assert Matcher(ITEMS).match(ref("Way Maker", "u0", 0), playlist).method == "header"
