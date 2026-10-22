// Map the active ProPresenter playlist item to a PCO plan item.
//
// Order of checks for an active ProPresenter item:
//   1. Ignore list -> never matched (pre-service loop, announcements, backups...).
//   2. Header items are never targets. ProPresenter can't "fire" a header, and
//      LIVE has nothing to record for one.
//   3. Aliases: an explicit ProPresenter-name -> PCO-title mapping from config.
//   4. Best guess. Every (ProPresenter entry, plan item) pair gets a score:
//        title      exact title, or the title without " - Person"
//                   ("Baptisms" = "BAPTISMS - Joey"), joined words
//                   ("Pre-roll" = "PREROLL"), plurals, or one name containing
//                   the other ("Bumper" ~ "SERMON BUMPER")
//        description  most words of the name appear at the top of the item's
//                   description ("Gospel of John - Week 3" ~ "MESSAGE - Jon",
//                   described "Gospel of John Week 4")
//        position   the Nth PCO-linked entry = the Nth plan item, when
//                   ProPresenter built the playlist from the plan
//      Then the whole playlist is lined up against the whole plan in order,
//      like a diff, keeping the line-up with the best total score. Repeated
//      songs pair up in order (the 1st "What A Worthy Name" before the
//      baptism, the 2nd after it), and entries added by hand in between don't
//      disturb anything.
//   5. When one ProPresenter entry could be several identical plan items (a
//      song used twice but in the playlist once), the result lists the others
//      as alternatives and the engine picks the next one ahead of LIVE.
// Anything else is unmatched, and an unmatched item never moves LIVE.

import Foundation

let regexPrefix = "regex:"

/// Scores below this never match.
let matchThreshold = 0.5
/// An entry that can't be lined up in order still matches if it scores this well.
let strongMatch = 0.9

public func normalize(_ text: String) -> String {
    var scalars = String.UnicodeScalarView()
    for s in text.decomposedStringWithCompatibilityMapping.unicodeScalars {
        switch s.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: continue
        default: scalars.append(s)
        }
    }
    let folded = String(scalars).lowercased().replacingOccurrences(of: "&", with: " and ")
    var out = ""
    var pendingSpace = false
    for s in folded.unicodeScalars {
        if "'‘’`".unicodeScalars.contains(s) { continue }
        let word = s.properties.isAlphabetic || s.properties.numericType != nil || s == "_"
        if word {
            if pendingSpace && !out.isEmpty { out.append(" ") }
            pendingSpace = false
            out.unicodeScalars.append(s)
        } else {
            pendingSpace = true
        }
    }
    return out
}

/// "BAPTISMS - Joey" -> "BAPTISMS". Plans name the person after a spaced dash.
func titleBase(_ title: String) -> String {
    for sep in [" - ", " – ", " — "] {
        if let r = title.range(of: sep) {
            let head = String(title[..<r.lowerBound])
            if !normalize(head).isEmpty { return head }
        }
    }
    return title
}

let stopwords: Set<String> = ["a", "an", "the", "of", "and", "to", "in", "for", "on", "at", "with"]

func stem(_ w: String) -> String {
    if w.count > 3 && w.hasSuffix("s") && !w.hasSuffix("ss") { return String(w.dropLast()) }
    return w
}

/// Content words, stemmed. Falls back to every word if all are stopwords.
func words(_ text: String) -> [String] {
    let all = normalize(text).split(separator: " ").map(String.init)
    let content = all.filter { !stopwords.contains($0) }
    return (content.isEmpty ? all : content).map(stem)
}

func compact(_ text: String) -> String {
    normalize(text).replacingOccurrences(of: " ", with: "")
}

/// How well `name`'s words are covered by `target`'s words: (name words found,
/// target words used). Two adjacent words on either side may equal one joined
/// word on the other ("pre roll" / "preroll").
func overlap(_ name: [String], _ target: [String]) -> (Int, Int) {
    var pairs: [String: Int] = [:]
    if target.count > 1 { for i in 0..<(target.count - 1) { pairs[target[i] + target[i + 1]] = i } }
    var usedT = Set<Int>()
    var found = 0
    var i = 0
    while i < name.count {
        if i + 1 < name.count, let j = target.firstIndex(of: name[i] + name[i + 1]), !usedT.contains(j) {
            usedT.insert(j)
            found += 2
            i += 2
            continue
        }
        if let j = target.indices.first(where: { target[$0] == name[i] && !usedT.contains($0) }) {
            usedT.insert(j)
            found += 1
        } else if let j = pairs[name[i]], !usedT.contains(j), !usedT.contains(j + 1) {
            usedT.insert(j)
            usedT.insert(j + 1)
            found += 1
        }
        i += 1
    }
    return (found, usedT.count)
}

public struct MatchResult {
    public let item: PlanItem?
    public let method: String  // ignored | header | alias | title | description | position | none
    public let reason: String
    public var score = 0.0
    /// Identical plan items (e.g. the same song used twice) this entry could
    /// equally be. The engine picks the next one ahead of LIVE.
    public var alternatives: [PlanItem] = []
    /// Something to double-check, e.g. "Week 3" here but "Week 4" in the plan.
    public var warning = ""

    public init(item: PlanItem?, method: String, reason: String, score: Double = 0,
                alternatives: [PlanItem] = [], warning: String = "") {
        self.item = item
        self.method = method
        self.reason = reason
        self.score = score
        self.alternatives = alternatives
        self.warning = warning
    }
}

public struct MatchSettings: Codable, Equatable {
    public var ignore: [String] = []
    public var aliases: [String: String] = [:]
    public var positionalFallback = true

    public init(ignore: [String] = [], aliases: [String: String] = [:], positionalFallback: Bool = true) {
        self.ignore = ignore
        self.aliases = aliases
        self.positionalFallback = positionalFallback
    }
}

struct Score {
    let value: Double
    let method: String
    let why: String
    var warning = ""
}

struct ItemKeys {
    let full: String
    let base: String
    let compactFull: String
    let compactBase: String
    let words: [String]
    let baseWords: [String]
    let descWords: [String]
    let descNumbers: [String]
}

/// One playlist line-up: playlist offset -> result.
struct Alignment {
    var byEntry: [Int: MatchResult] = [:]
    /// Plan items some ProPresenter entry can fire.
    var reachable: Set<String> = []
}

public final class Matcher {
    public let settings: MatchSettings
    public let items: [PlanItem]
    let targets: [PlanItem]  // non-header items in plan order
    private var keys: [String: ItemKeys] = [:]
    private var ignoreExact: Set<String> = []
    private var ignoreRegex: [NSRegularExpression] = []
    private var aliases: [String: String] = [:]
    private var cache: (playlist: [PPPlaylistItem], alignment: Alignment)?
    /// Ignore patterns that failed to compile, for the UI to report.
    public private(set) var badPatterns: [String] = []

    public init(_ planItems: [PlanItem], _ settings: MatchSettings = MatchSettings()) {
        self.settings = settings
        items = planItems.enumerated().sorted { ($0.element.sequence, $0.offset) < ($1.element.sequence, $1.offset) }.map(\.element)
        targets = items.filter { !$0.isHeader }
        for item in targets {
            let base = titleBase(item.title)
            let lines = item.description.split(whereSeparator: \.isNewline).map(String.init)
                .filter { !normalize($0).isEmpty }.prefix(3)
            let desc = words(lines.joined(separator: " "))
            keys[item.id] = ItemKeys(
                full: normalize(item.title), base: normalize(base),
                compactFull: compact(item.title), compactBase: compact(base),
                words: words(item.title), baseWords: words(base),
                descWords: desc, descNumbers: desc.filter(isNumber)
            )
        }
        for pattern in settings.ignore {
            if pattern.hasPrefix(regexPrefix) {
                let body = String(pattern.dropFirst(regexPrefix.count))
                if let re = try? NSRegularExpression(pattern: body, options: [.caseInsensitive]) {
                    ignoreRegex.append(re)
                } else {
                    badPatterns.append(pattern)
                }
            } else {
                ignoreExact.insert(normalize(pattern))
            }
        }
        for (k, v) in settings.aliases { aliases[normalize(k)] = normalize(v) }
    }

    public func isIgnored(_ name: String) -> Bool {
        if ignoreExact.contains(normalize(name)) { return true }
        let range = NSRange(name.startIndex..., in: name)
        return ignoreRegex.contains { $0.firstMatch(in: name, range: range) != nil }
    }

    // MARK: scoring

    func score(_ name: String, _ item: PlanItem) -> Score? {
        guard let k = keys[item.id] else { return nil }
        let n = normalize(name)
        if n.isEmpty { return nil }
        if let alias = aliases[n] {
            return alias == k.full || alias == k.base ? Score(value: 1.0, method: "alias", why: "alias") : nil
        }
        if n == k.full { return Score(value: 1.0, method: "title", why: "title match") }
        let c = compact(name)
        let nw = words(name)
        if n == k.base || c == k.compactFull || c == k.compactBase || (!nw.isEmpty && Set(nw) == Set(k.baseWords)) {
            return Score(value: 0.95, method: "title", why: "title match ('\(item.title)')")
        }
        var best: Score?
        func offer(_ s: Score) { if s.value > (best?.value ?? 0) { best = s } }

        // One name contains the other.
        let (found, used) = overlap(nw, k.words)
        if !nw.isEmpty && found == nw.count && !k.baseWords.isEmpty {
            offer(Score(value: 0.7 + 0.25 * min(1, Double(used) / Double(k.baseWords.count)), method: "title",
                        why: "'\(name)' is part of '\(item.title)'"))
        }
        let (foundB, usedB) = overlap(k.baseWords, nw)
        if !k.baseWords.isEmpty && foundB == k.baseWords.count {
            offer(Score(value: 0.7 + 0.25 * min(1, Double(usedB) / Double(nw.count)), method: "title",
                        why: "'\(titleBase(item.title))' is part of '\(name)'"))
        }
        // Some words in common.
        if found > 0 {
            let union = nw.count + k.words.count - found
            let f = Double(found) / Double(max(union, 1))
            offer(Score(value: 0.3 + 0.4 * f, method: "title", why: "shares words with '\(item.title)'"))
        }
        // The top of the description.
        if nw.count >= 2 && !k.descWords.isEmpty {
            let (d, _) = overlap(nw, k.descWords)
            let f = Double(d) / Double(nw.count)
            if f >= 0.6 {
                var s = Score(value: 0.5 + 0.3 * f, method: "description", why: "matches the description of '\(item.title)'")
                let mine = nw.filter(isNumber)
                if !mine.isEmpty && !k.descNumbers.isEmpty && Set(mine).isDisjoint(with: k.descNumbers) {
                    s.warning = "ProPresenter says \(mine.joined(separator: ", ")) but the plan says \(k.descNumbers.joined(separator: ", ")) (\"\(firstLine(item.description))\")"
                }
                offer(s)
            }
        }
        return best.flatMap { $0.value >= matchThreshold ? $0 : nil }
    }

    // MARK: matching

    public func match(_ active: PPRef, _ playlist: [PPPlaylistItem]? = nil) -> MatchResult {
        let name = active.name
        if isIgnored(name) {
            return MatchResult(item: nil, method: "ignored", reason: "'\(name)' is on the ignore list")
        }
        let list = playlist ?? []
        let entry = list.isEmpty ? nil : findEntry(active, list)
        if let e = entry, list[e].type == "header" {
            return MatchResult(item: nil, method: "header", reason: "'\(name)' is a ProPresenter header")
        }
        if let e = entry {
            if let r = align(list).byEntry[e] { return r }
            return MatchResult(item: nil, method: "none", reason: noMatchReason(name))
        }
        // No playlist to line up against: best single guess.
        let scored = targets.compactMap { t in score(name, t).map { (t, $0) } }
        guard let top = scored.max(by: { $0.1.value < $1.1.value }) else {
            return MatchResult(item: nil, method: "none", reason: noMatchReason(name))
        }
        let ties = scored.filter { $0.1.value >= top.1.value - 1e-9 }
        if ties.count > 1 && Set(ties.map { keys[$0.0.id]!.full }).count > 1 {
            return MatchResult(item: nil, method: "none", reason: "'\(name)' matches \(ties.count) different plan items equally well")
        }
        return MatchResult(item: ties[0].0, method: top.1.method, reason: top.1.why, score: top.1.value,
                           alternatives: ties.dropFirst().map(\.0), warning: top.1.warning)
    }

    func noMatchReason(_ name: String) -> String {
        "no PCO item titled like '\(name)'"
    }

    /// Plan items that some entry in this playlist can fire.
    public func reachableItemIds(_ playlist: [PPPlaylistItem]) -> Set<String> {
        align(playlist).reachable
    }

    func align(_ playlist: [PPPlaylistItem]) -> Alignment {
        if let c = cache, c.playlist == playlist { return c.alignment }
        let result = computeAlignment(playlist)
        cache = (playlist, result)
        return result
    }

    func computeAlignment(_ playlist: [PPPlaylistItem]) -> Alignment {
        let entries = playlist.indices.filter { playlist[$0].type != "header" && !isIgnored(playlist[$0].name) }
        let a = entries.count, b = targets.count
        var scores = [[Score?]](repeating: [Score?](repeating: nil, count: b), count: a)
        for (i, e) in entries.enumerated() {
            for (j, t) in targets.enumerated() { scores[i][j] = score(playlist[e].name, t) }
        }
        // PCO-linked entries line up by position when the counts agree.
        if settings.positionalFallback {
            let linked = entries.indices.filter { playlist[entries[$0]].isPCO }
            if !linked.isEmpty && linked.count == b {
                for (j, i) in linked.enumerated() where (scores[i][j]?.value ?? 0) < 0.6 {
                    scores[i][j] = Score(value: 0.6, method: "position", why: "positional match (PCO-linked entry \(j + 1))")
                }
            }
        }

        // Best in-order line-up (longest-common-subsequence style, weighted).
        var dp = [[Double]](repeating: [Double](repeating: 0, count: b + 1), count: a + 1)
        for i in stride(from: a - 1, through: 0, by: -1) {
            for j in stride(from: b - 1, through: 0, by: -1) {
                var v = max(dp[i + 1][j], dp[i][j + 1])
                if let s = scores[i][j] { v = max(v, s.value + dp[i + 1][j + 1]) }
                dp[i][j] = v
            }
        }
        var pairs: [Int: Int] = [:]  // entry row -> target column
        var i = 0, j = 0
        while i < a && j < b {
            if let s = scores[i][j], abs(dp[i][j] - (s.value + dp[i + 1][j + 1])) < 1e-9 {
                pairs[i] = j
                i += 1
                j += 1
            } else if dp[i][j] == dp[i + 1][j] {
                i += 1
            } else {
                j += 1
            }
        }
        // Strong matches that couldn't be lined up in order (the playlist is
        // in a different order than the plan) still count.
        let taken = Set(pairs.values)
        for r in 0..<a where pairs[r] == nil {
            let options = (0..<b).filter { !taken.contains($0) && (scores[r][$0]?.value ?? 0) >= strongMatch }
            if let best = options.max(by: { scores[r][$0]!.value < scores[r][$1]!.value }) { pairs[r] = best }
        }

        var out = Alignment()
        let assigned = Set(pairs.values)
        for (r, c) in pairs {
            let s = scores[r][c]!
            let t = targets[c]
            // Identical items nobody else claimed: the engine chooses by LIVE.
            let twins = targets.indices.filter { $0 != c && !assigned.contains($0) && keys[targets[$0].id]!.full == keys[t.id]!.full }
                .map { targets[$0] }
            out.byEntry[entries[r]] = MatchResult(item: t, method: s.method, reason: s.why, score: s.value,
                                                  alternatives: twins, warning: s.warning)
            out.reachable.insert(t.id)
            for tw in twins { out.reachable.insert(tw.id) }
        }
        for r in 0..<a where pairs[r] == nil {
            let e = entries[r]
            let near = (0..<b).compactMap { c in scores[r][c].map { (c, $0) } }.max { $0.1.value < $1.1.value }
            let reason = near.map { "best guess '\(targets[$0.0].title)' is already matched to another entry" } ?? noMatchReason(playlist[e].name)
            out.byEntry[e] = MatchResult(item: nil, method: "none", reason: reason)
        }
        return out
    }
}

func isNumber(_ w: String) -> Bool {
    !w.isEmpty && w.unicodeScalars.allSatisfy { $0.properties.numericType != nil }
}

func firstLine(_ text: String) -> String {
    text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
}

/// Offset in `playlist` of the entry ProPresenter reports as active.
/// ProPresenter gives every copy of a presentation in a playlist the same
/// uuid (a song used twice), so the index decides between copies.
func findEntry(_ active: PPRef, _ playlist: [PPPlaylistItem]) -> Int? {
    let sameUUID = active.uuid.isEmpty ? [] : playlist.indices.filter { playlist[$0].uuid == active.uuid }
    if sameUUID.count == 1 { return sameUUID[0] }
    if let idx = active.index {
        let pool = sameUUID.isEmpty ? Array(playlist.indices) : sameUUID
        if let n = pool.first(where: { playlist[$0].index == idx }) { return n }
        if sameUUID.isEmpty && idx >= 0 && idx < playlist.count && playlist[idx].name == active.name { return idx }
    }
    return sameUUID.first
}
