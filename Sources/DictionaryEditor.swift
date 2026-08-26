import Foundation

/// 辞書ファイルを壊さずに検索・更新するための、副作用を持たない処理。
///
/// アプリ本体は使わない。辞書スキルの `manage.sh` と `./test.sh` から同じ実装を呼ぶ。
/// 曖昧検索は候補を返すだけで、書き換えは左辺の完全一致に限る。
enum DictionaryEditor {

    struct Entry {
        let line: Int
        let from: String
        let to: String
        let raw: String
        let candidate: Bool
    }

    struct Match {
        let entry: Entry
        let fragment: String
        let exact: Bool
    }

    enum EditError: Error, CustomStringConvertible {
        case invalid(String)
        case notFound(String)
        case ambiguous(String, [Int])
        case conflict(String, Int)

        var description: String {
            switch self {
            case .invalid(let reason): return reason
            case .notFound(let from): return "左辺「\(from)」は見つかりません"
            case .ambiguous(let from, let lines):
                return "左辺「\(from)」が複数あります（\(lines.map(String.init).joined(separator: ", ")) 行）"
            case .conflict(let from, let line):
                return "変更後の左辺「\(from)」はすでに \(line) 行目にあります"
            }
        }
    }

    enum Change: Equatable {
        case inserted(line: Int)
        case updated(line: Int)
        case promoted(line: Int)
        case replaced(line: Int)
        case deleted(line: Int)
    }

    static func entries(in text: String) -> [Entry] {
        text.components(separatedBy: "\n").enumerated().compactMap { offset, raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let candidate = trimmed.hasPrefix("#?")
            if trimmed.hasPrefix("#") && !candidate { return nil }

            let body = candidate
                ? String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                : raw
            guard let rule = splitRule(body) else { return nil }
            return Entry(line: offset + 1,
                         from: rule.from,
                         to: rule.to,
                         raw: raw,
                         candidate: candidate)
        }
    }

    /// まず問い合わせ全体を固定文字列として探す。無ければ各項目との最長共通部分を取り、
    /// 問い合わせを少しずつ切り詰めたのと同じ候補を返す。
    static func find(_ query: String, in text: String, limit: Int = 10) -> [Match] {
        let q = normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !q.isEmpty else { return [] }
        let all = entries(in: text)

        let exact = all.filter { entry in
            searchable(entry).contains { normalized($0).contains(q) }
        }.map { Match(entry: $0, fragment: query, exact: true) }
        if !exact.isEmpty {
            return Array(exact.sorted(by: matchOrder).prefix(limit))
        }

        let minimum = q.unicodeScalars.allSatisfy(\.isASCII) ? 3 : 2
        let fuzzy = all.compactMap { entry -> Match? in
            var best = ""
            for field in searchable(entry) {
                let fragment = longestCommonSubstring(q, normalized(field))
                if fragment.count > best.count { best = fragment }
            }
            guard best.count >= minimum else { return nil }
            return Match(entry: entry, fragment: best, exact: false)
        }.sorted {
            if $0.fragment.count != $1.fragment.count { return $0.fragment.count > $1.fragment.count }
            return matchOrder($0, $1)
        }
        return Array(fuzzy.prefix(limit))
    }

    /// 左辺があれば右辺を更新し、無ければ末尾へ追加する。
    /// 同じ左辺の候補行（`#?`）が1つだけあれば、その場で本登録へ昇格する。
    static func upsert(from: String, to: String, in text: String) throws -> (String, Change) {
        try validate(from: from, to: to)
        let all = entries(in: text)
        let active = all.filter { !$0.candidate && $0.from == from }
        if active.count > 1 { throw EditError.ambiguous(from, active.map(\.line)) }
        if let entry = active.first {
            let next = replacingLine(entry.line, with: rendered(from: from, to: to, preservingCommentFrom: entry.raw), in: text)
            return (next, .updated(line: entry.line))
        }

        let candidates = all.filter { $0.candidate && $0.from == from }
        if candidates.count > 1 { throw EditError.ambiguous(from, candidates.map(\.line)) }
        if let entry = candidates.first {
            let next = replacingLine(entry.line, with: rendered(from: from, to: to), in: text)
            return (next, .promoted(line: entry.line))
        }

        var next = text
        if !next.isEmpty && !next.hasSuffix("\n") { next += "\n" }
        next += rendered(from: from, to: to) + "\n"
        return (next, .inserted(line: next.components(separatedBy: "\n").count - 1))
    }

    /// 左辺と右辺を一度に直す。検索で見つけた古い左辺は完全一致で渡す。
    static func replace(oldFrom: String, newFrom: String, newTo: String, in text: String) throws -> (String, Change) {
        try validate(from: newFrom, to: newTo)
        let all = entries(in: text)
        let old = all.filter { !$0.candidate && $0.from == oldFrom }
        guard !old.isEmpty else { throw EditError.notFound(oldFrom) }
        if old.count > 1 { throw EditError.ambiguous(oldFrom, old.map(\.line)) }
        let entry = old[0]
        if let conflict = all.first(where: { !$0.candidate && $0.from == newFrom && $0.line != entry.line }) {
            throw EditError.conflict(newFrom, conflict.line)
        }
        let line = rendered(from: newFrom, to: newTo, preservingCommentFrom: entry.raw)
        return (replacingLine(entry.line, with: line, in: text), .replaced(line: entry.line))
    }

    /// 本登録・候補を問わず、左辺が完全一致する1行だけを削除する。
    static func delete(from: String, in text: String) throws -> (String, Change) {
        let found = entries(in: text).filter { $0.from == from }
        guard !found.isEmpty else { throw EditError.notFound(from) }
        if found.count > 1 { throw EditError.ambiguous(from, found.map(\.line)) }
        let entry = found[0]
        return (removingLine(entry.line, in: text), .deleted(line: entry.line))
    }

    // MARK: - 内部処理

    private static func validate(from: String, to: String) throws {
        guard !from.isEmpty else { throw EditError.invalid("左辺は空にできません") }
        guard !to.isEmpty else { throw EditError.invalid("右辺は空にできません。消す場合は delete を使ってください") }
        let reserved = ["#", "=>", "→", "\t", "\n", "\r"]
        guard !reserved.contains(where: { from.contains($0) || to.contains($0) }) else {
            throw EditError.invalid("左辺と右辺には、コメント・区切り・改行の記号を書けません")
        }
        guard from != to else { throw EditError.invalid("左右が同じ規則は登録できません") }
        guard !to.contains(from) else {
            throw EditError.invalid("左辺が右辺の一部です。正しい文章を繰り返し壊すため登録できません")
        }
    }

    private static func splitRule(_ raw: String) -> (from: String, to: String)? {
        var line = raw
        if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) }
        let separators = ["=>", "→", "\t"]
        let hits = separators.compactMap { separator -> (String, Range<String.Index>)? in
            line.range(of: separator).map { (separator, $0) }
        }
        guard let hit = hits.min(by: { $0.1.lowerBound < $1.1.lowerBound }) else { return nil }
        let from = String(line[..<hit.1.lowerBound]).trimmingCharacters(in: .whitespaces)
        let to = String(line[hit.1.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !from.isEmpty else { return nil }
        return (from, to)
    }

    private static func searchable(_ entry: Entry) -> [String] {
        [entry.from, entry.to, entry.raw]
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "ja_JP"))
    }

    private static func longestCommonSubstring(_ lhs: String, _ rhs: String) -> String {
        let a = Array(lhs)
        let b = Array(rhs)
        guard !a.isEmpty, !b.isEmpty else { return "" }
        var previous = Array(repeating: 0, count: b.count + 1)
        var bestLength = 0
        var bestEnd = 0
        for i in 1...a.count {
            var current = Array(repeating: 0, count: b.count + 1)
            for j in 1...b.count where a[i - 1] == b[j - 1] {
                current[j] = previous[j - 1] + 1
                if current[j] > bestLength {
                    bestLength = current[j]
                    bestEnd = i
                }
            }
            previous = current
        }
        guard bestLength > 0 else { return "" }
        return String(a[(bestEnd - bestLength)..<bestEnd])
    }

    private static func matchOrder(_ lhs: Match, _ rhs: Match) -> Bool {
        if lhs.entry.candidate != rhs.entry.candidate { return !lhs.entry.candidate }
        return lhs.entry.line < rhs.entry.line
    }

    private static func rendered(from: String, to: String, preservingCommentFrom raw: String? = nil) -> String {
        let comment = raw.flatMap { line -> String? in
            guard let hash = line.firstIndex(of: "#") else { return nil }
            return String(line[hash...]).trimmingCharacters(in: .whitespaces)
        }
        return ["\(from) => \(to)", comment].compactMap { $0 }.joined(separator: "  ")
    }

    private static func replacingLine(_ number: Int, with replacement: String, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        lines[number - 1] = replacement
        return lines.joined(separator: "\n")
    }

    private static func removingLine(_ number: Int, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        lines.remove(at: number - 1)
        return lines.joined(separator: "\n")
    }
}
