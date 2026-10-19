// Map the active ProPresenter playlist item to a PCO plan item.
//
// Order of checks for an active ProPresenter item:
//   1. Ignore list -> never matched (pre-service loop, announcements, backups...).
//   2. Header items are never targets. ProPresenter can't "fire" a header, and
//      LIVE has nothing to record for one.
//   3. Aliases: an explicit ProPresenter-name -> PCO-title mapping from config.
//   4. Normalized title match (case/punctuation/whitespace/accents ignored).
//      When several plan items share a title (e.g. two "Prayer" items), the Nth
//      same-named item in the playlist maps to the Nth same-titled plan item.
//   5. Positional fallback (optional): if the playlist was generated from the
//      PCO plan, ProPresenter marks those entries `is_pco`. When the count of
//      `is_pco` entries equals the plan's item count, entry N maps to item N.
//      Items the operator added by hand (not `is_pco`) never match positionally.
// Anything else is unmatched, and an unmatched item never moves LIVE.

import Foundation

let regexPrefix = "regex:"

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

public struct MatchResult {
    public let item: PlanItem?
    public let method: String  // ignored | header | alias | title | position | none
    public let reason: String
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

public final class Matcher {
    public let settings: MatchSettings
    public let items: [PlanItem]
    private var byTitle: [String: [PlanItem]] = [:]
    private var ignoreExact: Set<String> = []
    private var ignoreRegex: [NSRegularExpression] = []
    private var aliases: [String: String] = [:]
    /// Ignore patterns that failed to compile, for the UI to report.
    public private(set) var badPatterns: [String] = []

    public init(_ planItems: [PlanItem], _ settings: MatchSettings = MatchSettings()) {
        self.settings = settings
        items = planItems.enumerated().sorted { ($0.element.sequence, $0.offset) < ($1.element.sequence, $1.offset) }.map(\.element)
        for item in items where !item.isHeader {
            byTitle[normalize(item.title), default: []].append(item)
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

        var key = normalize(name)
        var method = "title"
        if let alias = aliases[key] {
            key = alias
            method = "alias"
        }

        let candidates = byTitle[key] ?? []
        if candidates.count == 1 {
            return MatchResult(item: candidates[0], method: method, reason: "\(method) match")
        }
        if candidates.count > 1 {
            if !list.isEmpty, let rank = occurrenceRank(entry, list, key), rank < candidates.count {
                return MatchResult(item: candidates[rank], method: method, reason: "\(method) match (occurrence \(rank + 1) of \(candidates.count))")
            }
            return MatchResult(item: nil, method: "none", reason: "'\(name)' matches \(candidates.count) plan items and position is ambiguous")
        }

        if settings.positionalFallback, !list.isEmpty, let e = entry, let result = positional(e, list) {
            return result
        }
        return MatchResult(item: nil, method: "none", reason: "no PCO item titled like '\(name)'")
    }

    private func positional(_ entry: Int, _ playlist: [PPPlaylistItem]) -> MatchResult? {
        guard playlist[entry].isPCO else { return nil }
        var pcoEntries = playlist.indices.filter { playlist[$0].isPCO }
        var plan = items
        if pcoEntries.count != items.count {
            // Retry without headers in case one side dropped them.
            pcoEntries = pcoEntries.filter { playlist[$0].type != "header" }
            plan = items.filter { !$0.isHeader }
            if pcoEntries.count != plan.count { return nil }
        }
        guard let pos = pcoEntries.firstIndex(of: entry) else { return nil }
        let target = plan[pos]
        if target.isHeader {
            return MatchResult(item: nil, method: "header", reason: "position \(pos + 1) is a PCO header")
        }
        return MatchResult(item: target, method: "position", reason: "positional match (PCO-linked entry \(pos + 1))")
    }

    private func occurrenceRank(_ entry: Int?, _ playlist: [PPPlaylistItem], _ key: String) -> Int? {
        guard let entry = entry else { return nil }
        var rank = 0
        for (n, p) in playlist.enumerated() {
            if n == entry { return rank }
            if p.type == "header" { continue }
            let pkey = normalize(p.name)
            if (aliases[pkey] ?? pkey) == key { rank += 1 }
        }
        return nil
    }
}

/// Offset in `playlist` of the entry ProPresenter reports as active.
func findEntry(_ active: PPRef, _ playlist: [PPPlaylistItem]) -> Int? {
    if !active.uuid.isEmpty, let n = playlist.firstIndex(where: { $0.uuid == active.uuid }) {
        return n
    }
    if let idx = active.index {
        if let n = playlist.firstIndex(where: { $0.index == idx }) { return n }
        if idx >= 0 && idx < playlist.count && playlist[idx].name == active.name { return idx }
    }
    return nil
}
