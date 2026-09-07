import Foundation

/// Subsequence matching with a score, for a search field that has to feel like it read
/// your mind from three keystrokes.
///
/// Substring matching is not enough: someone typing `wpr` expects `web-prod`, and someone
/// typing `dfh` expects `df -h`. Both are subsequences, and the difference between a
/// palette that is useful and one that is noise is entirely in the *ranking* — which of
/// forty subsequence matches goes first.
///
/// The scoring follows the shape used by editors people already know: consecutive
/// characters are worth much more than scattered ones, a match at the start of a word is
/// worth more than one in the middle, and unmatched leading characters cost.
public enum FuzzyMatch {
    /// A match, with the positions that matched so they can be highlighted.
    public struct Result: Equatable, Sendable {
        public let score: Int
        /// Indices into the candidate, in order, for emphasising the matched characters.
        public let matchedIndices: [Int]
    }

    private enum Score {
        /// Two matched characters next to each other. Dominates everything else, because
        /// a run of three is almost always what the user meant.
        static let consecutive = 15
        /// The first character of a word — after a space, `-`, `_`, `.`, `/`, or at a
        /// lowercase-to-uppercase boundary.
        static let wordStart = 10
        /// Matching the first character of the candidate at all.
        static let prefix = 8
        /// Same case as typed. A weak signal, but it separates `DF` from `df`.
        static let sameCase = 1
        /// Each unmatched character before the first match.
        static let leadingPenalty = -1
        /// Each unmatched character between matches.
        static let gapPenalty = -1
    }

    /// Scores `candidate` against `query`, or returns `nil` if it is not a match at all.
    ///
    /// An empty query matches everything with a score of zero, so a palette shows its
    /// full list before anything is typed.
    public static func score(_ candidate: String, query: String) -> Result? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Result(score: 0, matchedIndices: []) }

        let haystack = Array(candidate)
        let needle = Array(trimmed)
        guard !haystack.isEmpty, needle.count <= haystack.count else { return nil }

        var indices: [Int] = []
        indices.reserveCapacity(needle.count)
        var total = 0
        var searchFrom = 0

        for (position, wanted) in needle.enumerated() {
            guard let found = firstIndex(of: wanted, in: haystack, from: searchFrom) else { return nil }

            if position == 0 {
                total += found * Score.leadingPenalty
                if found == 0 { total += Score.prefix }
            } else {
                let gap = found - (indices[position - 1] + 1)
                if gap == 0 {
                    total += Score.consecutive
                } else {
                    total += gap * Score.gapPenalty
                }
            }
            if isWordStart(at: found, in: haystack) { total += Score.wordStart }
            if haystack[found] == wanted { total += Score.sameCase }

            indices.append(found)
            searchFrom = found + 1
        }

        // A short candidate that matched is a better answer than a long one that also
        // did: `df` beats `dpkg --force-confold` for the query `df`.
        total -= haystack.count / 8
        return Result(score: total, matchedIndices: indices)
    }

    /// Ranks candidates, dropping the ones that do not match.
    ///
    /// Ties are broken by the caller's original order, which is stable and usually
    /// meaningful — most-used first, or alphabetical.
    public static func rank<T>(
        _ items: [T],
        query: String,
        by text: (T) -> String
    ) -> [(item: T, result: Result)] {
        var scored: [(offset: Int, item: T, result: Result)] = []
        scored.reserveCapacity(items.count)
        for (offset, item) in items.enumerated() {
            guard let result = score(text(item), query: query) else { continue }
            scored.append((offset: offset, item: item, result: result))
        }
        scored.sort { left, right in
            if left.result.score != right.result.score { return left.result.score > right.result.score }
            return left.offset < right.offset
        }
        return scored.map { (item: $0.item, result: $0.result) }
    }

    private static func firstIndex(of wanted: Character, in haystack: [Character], from: Int) -> Int? {
        guard from < haystack.count else { return nil }
        let lowered = Character(wanted.lowercased())
        for index in from ..< haystack.count where Character(haystack[index].lowercased()) == lowered {
            return index
        }
        return nil
    }

    private static func isWordStart(at index: Int, in haystack: [Character]) -> Bool {
        guard index > 0 else { return true }
        let previous = haystack[index - 1]
        if previous == " " || previous == "-" || previous == "_" || previous == "." || previous == "/" {
            return true
        }
        // `webProd` — the P starts a word even though nothing separates it.
        return previous.isLowercase && haystack[index].isUppercase
    }
}
