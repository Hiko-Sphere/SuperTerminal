import Foundation
import STCore
import Testing

/// The palette is only as good as its ranking: with forty subsequence matches, which one
/// is first is the entire feature.
@Suite("Fuzzy matching")
struct FuzzyMatchTests {
    private func best(_ query: String, among candidates: [String]) -> String? {
        FuzzyMatch.rank(candidates, query: query) { $0 }.first?.item
    }

    @Test("An empty query matches everything, so the palette opens with a full list")
    func emptyQueryMatchesEverything() {
        #expect(FuzzyMatch.score("anything", query: "")?.score == 0)
        #expect(FuzzyMatch.score("anything", query: "   ")?.score == 0)
    }

    @Test("Characters must appear in order")
    func orderMatters() {
        #expect(FuzzyMatch.score("web-prod", query: "wpr") != nil)
        #expect(FuzzyMatch.score("web-prod", query: "rpw") == nil, "out of order is not a match")
    }

    @Test("A query longer than the candidate cannot match")
    func tooLongIsNotAMatch() {
        #expect(FuzzyMatch.score("db", query: "database") == nil)
    }

    @Test("Matching is case-insensitive")
    func caseInsensitive() {
        #expect(FuzzyMatch.score("Web-Prod", query: "wp") != nil)
        #expect(FuzzyMatch.score("web-prod", query: "WP") != nil)
    }

    @Test("Initials beat scattered letters")
    func initialsWin() {
        // Someone typing "wp" means web-prod, not "wrapper".
        #expect(best("wp", among: ["wrapper", "web-prod"]) == "web-prod")
    }

    @Test("Consecutive characters beat spread-out ones")
    func consecutiveWins() {
        #expect(best("prod", among: ["p-r-o-d", "prod-db"]) == "prod-db")
    }

    @Test("A prefix beats a match in the middle")
    func prefixWins() {
        #expect(best("db", among: ["backup-db", "db-primary"]) == "db-primary")
    }

    @Test("A short candidate beats a long one that also matches")
    func shorterWins() {
        // Both match `df`; the one that is nearly all query is what was meant.
        #expect(best("df", among: ["dpkg --force-confold --refresh", "df -h"]) == "df -h")
    }

    @Test("Matched positions are reported in order, for highlighting")
    func matchedIndicesAreUsable() {
        let result = FuzzyMatch.score("web-prod", query: "wpr")
        #expect(result?.matchedIndices == [0, 4, 5])
        #expect(result?.matchedIndices == result?.matchedIndices.sorted())
    }

    @Test("Ranking drops non-matches and keeps the caller's order for ties")
    func rankingIsStable() {
        let items = ["alpha", "alpine", "zzz"]
        let ranked = FuzzyMatch.rank(items, query: "alp") { $0 }
        #expect(ranked.count == 2, "zzz does not match")
        // Identical prefixes and lengths differ only by the caller's order, which is
        // usually meaningful — most-used first, or alphabetical.
        #expect(ranked.map(\.item) == ["alpha", "alpine"])
    }

    @Test("A word boundary inside a name is found")
    func camelCaseBoundaries() {
        // `wp` should find the P of Prod even with nothing separating the words.
        let result = FuzzyMatch.score("webProd", query: "wp")
        #expect(result?.matchedIndices == [0, 3])
    }

    @Test("Real host names rank the way a person would expect")
    func realisticHostRanking() {
        let hosts = ["backup-nightly", "web-prod-01", "web-staging", "worker-pool-3"]
        #expect(best("wp", among: hosts) == "web-prod-01")
        #expect(best("ws", among: hosts) == "web-staging")
        #expect(best("bn", among: hosts) == "backup-nightly")
    }

    @Test("Real commands rank the way a person would expect")
    func realisticCommandRanking() {
        let commands = ["df -h", "docker ps", "journalctl -f", "free -m"]
        #expect(best("dps", among: commands) == "docker ps")
        #expect(best("jf", among: commands) == "journalctl -f")
    }
}
