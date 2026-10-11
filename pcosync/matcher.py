"""Map the active ProPresenter playlist item to a PCO plan item.

Order of checks for an active ProPresenter item:
  1. Ignore list -> never matched (pre-service loop, announcements, backups...).
  2. Header items are never targets. ProPresenter can't "fire" a header, and
     LIVE has nothing to record for one.
  3. Aliases: an explicit ProPresenter-name -> PCO-title mapping from config.
  4. Normalized title match (case/punctuation/whitespace/accents ignored).
     When several plan items share a title (e.g. two "Prayer" items), the Nth
     same-named item in the playlist maps to the Nth same-titled plan item.
  5. Positional fallback (optional): if the playlist was generated from the
     PCO plan, ProPresenter marks those entries `is_pco`. When the count of
     `is_pco` entries equals the plan's item count, entry N maps to item N.
     Items the operator added by hand (not `is_pco`) never match positionally.
Anything else is unmatched, and an unmatched item never moves LIVE.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass, field

from pcosync.pco import PlanItem
from pcosync.propresenter import PPPlaylistItem, PPRef

REGEX_PREFIX = "regex:"


def normalize(text: str) -> str:
    text = unicodedata.normalize("NFKD", text)
    text = "".join(ch for ch in text if not unicodedata.combining(ch))
    text = text.casefold().replace("&", " and ")
    text = re.sub(r"['‘’`]", "", text)
    text = re.sub(r"[^\w]+", " ", text)
    return " ".join(text.split())


@dataclass(frozen=True)
class MatchResult:
    item: PlanItem | None
    method: str  # ignored | header | alias | title | position | none
    reason: str


@dataclass
class MatchSettings:
    ignore: list[str] = field(default_factory=list)
    aliases: dict[str, str] = field(default_factory=dict)
    positional_fallback: bool = True


class Matcher:
    def __init__(self, plan_items: list[PlanItem], settings: MatchSettings | None = None):
        self.settings = settings or MatchSettings()
        self.items = sorted(plan_items, key=lambda i: i.sequence)
        self._by_title: dict[str, list[PlanItem]] = {}
        for item in self.items:
            if not item.is_header:
                self._by_title.setdefault(normalize(item.title), []).append(item)
        self._ignore_exact = set()
        self._ignore_re = []
        for pattern in self.settings.ignore:
            if pattern.startswith(REGEX_PREFIX):
                self._ignore_re.append(re.compile(pattern[len(REGEX_PREFIX):], re.IGNORECASE))
            else:
                self._ignore_exact.add(normalize(pattern))
        self._aliases = {normalize(k): normalize(v) for k, v in self.settings.aliases.items()}

    def is_ignored(self, name: str) -> bool:
        return normalize(name) in self._ignore_exact or any(r.search(name) for r in self._ignore_re)

    def match(self, active: PPRef, playlist: list[PPPlaylistItem] | None = None) -> MatchResult:
        name = active.name
        if self.is_ignored(name):
            return MatchResult(None, "ignored", f"'{name}' is on the ignore list")

        entry = _find_entry(active, playlist) if playlist else None
        if entry is not None and entry.type == "header":
            return MatchResult(None, "header", f"'{name}' is a ProPresenter header")

        key = normalize(name)
        method = "title"
        if key in self._aliases:
            key = self._aliases[key]
            method = "alias"

        candidates = self._by_title.get(key, [])
        if len(candidates) == 1:
            return MatchResult(candidates[0], method, f"{method} match")
        if len(candidates) > 1:
            rank = _occurrence_rank(active, entry, playlist, key, self._aliases) if playlist else None
            if rank is not None and rank < len(candidates):
                return MatchResult(candidates[rank], method, f"{method} match (occurrence {rank + 1} of {len(candidates)})")
            return MatchResult(None, "none", f"'{name}' matches {len(candidates)} plan items and position is ambiguous")

        if self.settings.positional_fallback and playlist and entry is not None:
            result = self._positional(entry, playlist)
            if result is not None:
                return result

        return MatchResult(None, "none", f"no PCO item titled like '{name}'")

    def _positional(self, entry: PPPlaylistItem, playlist: list[PPPlaylistItem]) -> MatchResult | None:
        if not entry.is_pco:
            return None
        pco_entries = [p for p in playlist if p.is_pco]
        if len(pco_entries) == len(self.items):
            plan = self.items
        else:
            # Retry without headers in case one side dropped them.
            pco_entries = [p for p in pco_entries if p.type != "header"]
            plan = [i for i in self.items if not i.is_header]
            if len(pco_entries) != len(plan):
                return None
        pos = next((n for n, p in enumerate(pco_entries) if p is entry), None)
        if pos is None:
            return None
        target = plan[pos]
        if target.is_header:
            return MatchResult(None, "header", f"position {pos + 1} is a PCO header")
        return MatchResult(target, "position", f"positional match (PCO-linked entry {pos + 1})")


def _find_entry(active: PPRef, playlist: list[PPPlaylistItem]) -> PPPlaylistItem | None:
    if active.uuid:
        for p in playlist:
            if p.uuid == active.uuid:
                return p
    if active.index is not None:
        for p in playlist:
            if p.index == active.index:
                return p
        if 0 <= active.index < len(playlist) and playlist[active.index].name == active.name:
            return playlist[active.index]
    return None


def _occurrence_rank(
    active: PPRef,
    entry: PPPlaylistItem | None,
    playlist: list[PPPlaylistItem],
    key: str,
    aliases: dict[str, str],
) -> int | None:
    if entry is None:
        return None
    rank = 0
    for p in playlist:
        if p is entry:
            return rank
        if p.type == "header":
            continue
        pkey = normalize(p.name)
        if aliases.get(pkey, pkey) == key:
            rank += 1
    return None
