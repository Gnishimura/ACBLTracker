import Foundation
import Combine

// USACBL scoring (Rules tab, B.4 and B.5):
//  - A player's points come from his NBA team's first 2 games of the Tue-Mon week.
//  - Starters get full points. Starter bonus per game: 30-39 = +2, 40+ = +5 (not stacked).
//  - If a starter doesn't play, the first-listed sub at the same position takes his place.
//  - The next 3 subs (in preferential order) who play are "playing subs": half points, rounded up, no bonus.
//  - A sub who is promoted or who doesn't play is skipped; the next reserve moves into the playing-sub role.

struct ScoringRules {
    var bonus30: Int = 2
    var bonus40: Int = 5
    var playingSubCount: Int = 3

    func bonus(for points: Int) -> Int {
        if points >= 40 { return bonus40 }
        if points >= 30 { return bonus30 }
        return 0
    }

    func subPoints(_ points: Int) -> Int { (points + 1) / 2 }
}

/// What we know about one player's nth team game of the week.
enum Availability: Equatable, Codable {
    case pending          // game not started (or no data yet) - assumed to play for provisional scoring
    case live(Int)
    case played(Int)
    case dnp

    var points: Int {
        switch self {
        case .live(let p), .played(let p): return p
        default: return 0
        }
    }

    var isDNP: Bool { if case .dnp = self { return true }; return false }
}

enum Role: Equatable, Codable {
    case starter
    case promoted        // a sub who moved into the starting unit
    case playingSub      // half points
    case notCounted      // deep reserve, or DNP
}

struct PlayerGameResult: Equatable, Codable {
    var role: Role
    var availability: Availability
    var replacing: UUID? = nil
    var countedPoints: Int
    var bonus: Int

    var rawPoints: Int { availability.points }
    var total: Int { countedPoints + bonus }
    var isCounted: Bool { role != .notCounted }
}

enum ScoringEngine {
    /// Resolves one "game number" (a team's 1st or 2nd game of the week) for the whole lineup.
    static func resolve(
        lineup: Lineup,
        availability: [UUID: Availability],
        rules: ScoringRules
    ) -> [UUID: PlayerGameResult] {
        var results: [UUID: PlayerGameResult] = [:]

        func avail(_ p: RosterPlayer) -> Availability { availability[p.id] ?? .pending }

        let subs = lineup.subs
        var promoted = Set<UUID>()
        var startingUnit: [(player: RosterPlayer, replacing: UUID?)] = []

        for starter in lineup.starters {
            if !avail(starter).isDNP {
                startingUnit.append((starter, nil))
                continue
            }
            results[starter.id] = PlayerGameResult(
                role: .notCounted, availability: .dnp, countedPoints: 0, bonus: 0
            )
            let replacement = subs.first {
                $0.position == starter.position && !promoted.contains($0.id) && !avail($0).isDNP
            }
            if let replacement {
                promoted.insert(replacement.id)
                startingUnit.append((replacement, starter.id))
            }
            // No eligible sub at that position: the slot scores zero.
        }

        for entry in startingUnit {
            let a = avail(entry.player)
            let raw = a.points
            results[entry.player.id] = PlayerGameResult(
                role: entry.replacing == nil ? .starter : .promoted,
                availability: a,
                replacing: entry.replacing,
                countedPoints: raw,
                bonus: rules.bonus(for: raw)
            )
        }

        var playingSubs = 0
        for sub in subs where !promoted.contains(sub.id) {
            let a = avail(sub)
            if a.isDNP {
                results[sub.id] = PlayerGameResult(role: .notCounted, availability: a, countedPoints: 0, bonus: 0)
            } else if playingSubs < rules.playingSubCount {
                playingSubs += 1
                results[sub.id] = PlayerGameResult(
                    role: .playingSub, availability: a,
                    countedPoints: rules.subPoints(a.points), bonus: 0
                )
            } else {
                results[sub.id] = PlayerGameResult(role: .notCounted, availability: a, countedPoints: 0, bonus: 0)
            }
        }

        return results
    }
}
