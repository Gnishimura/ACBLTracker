import Foundation
import Combine

// MARK: - League positions (set by the league's pre-draft list, not by ESPN)

enum Position: String, Codable, CaseIterable, Identifiable, Hashable {
    case G, F, C
    var id: String { rawValue }

    /// Best-effort mapping from ESPN's position abbreviations (PG, SG, SF, PF, F-C ...).
    static func fromESPN(_ abbr: String) -> Position {
        let a = abbr.uppercased()
        if a == "C" { return .C }
        if a.contains("F") { return .F }
        return .G
    }
}

// MARK: - Roster + lineup

struct RosterPlayer: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var position: Position
    /// Team as written on the league sheet (e.g. "NYK"). Only a hint for matching.
    var teamHint: String
    /// ESPN athlete id once the player has been matched in the directory.
    var espnID: String?

    /// An unfilled roster slot is a player with no name.
    var isEmpty: Bool { name.isEmpty }

    static func empty(_ position: Position = .G) -> RosterPlayer {
        RosterPlayer(name: "", position: position, teamHint: "", espnID: nil)
    }
}

enum SlotID: Hashable, Identifiable {
    case starter(Int)
    case bench(Int)
    case deep(Int)

    var id: SlotID { self }
    var isStarter: Bool { if case .starter = self { return true }; return false }

    /// Text form used while dragging a row, e.g. "starter-2".
    var payload: String {
        switch self {
        case .starter(let i): return "starter-\(i)"
        case .bench(let i): return "bench-\(i)"
        case .deep(let i): return "deep-\(i)"
        }
    }

    init?(payload: String) {
        let parts = payload.split(separator: "-")
        guard parts.count == 2, let i = Int(parts[1]) else { return nil }
        switch parts[0] {
        case "starter" where (0..<5).contains(i): self = .starter(i)
        case "bench" where (0..<3).contains(i): self = .bench(i)
        case "deep" where (0..<6).contains(i): self = .deep(i)
        default: return nil
        }
    }
}

/// 14-man roster laid out the way USACBL lineups are submitted:
/// 5 starters (G, G, F, F, C), 3 bench (playing subs), 6 deep bench.
struct Lineup: Codable, Equatable {
    var teamName: String
    var starters: [RosterPlayer]
    var bench: [RosterPlayer]
    var deep: [RosterPlayer]

    static let starterPositions: [Position] = [.G, .G, .F, .F, .C]

    /// A brand-new roster: 14 empty slots.
    static func blank(teamName: String = "My Team") -> Lineup {
        Lineup(
            teamName: teamName,
            starters: starterPositions.map { RosterPlayer.empty($0) },
            bench: (0..<3).map { _ in RosterPlayer.empty() },
            deep: (0..<6).map { _ in RosterPlayer.empty() }
        )
    }

    var isEmpty: Bool { all.allSatisfy { $0.isEmpty } }

    func contains(espnID: String) -> Bool { all.contains { $0.espnID == espnID } }

    /// Where a newly added player lands: an open starter slot at his position,
    /// else the first open bench spot, else the first open deep-bench spot.
    func firstOpenSlot(for position: Position) -> SlotID? {
        for i in starters.indices where starters[i].isEmpty && Lineup.starterPositions[i] == position {
            return .starter(i)
        }
        for i in bench.indices where bench[i].isEmpty { return .bench(i) }
        for i in deep.indices where deep[i].isEmpty { return .deep(i) }
        return nil
    }

    /// The nine substitutes in preferential order (bench first, then deep bench).
    var subs: [RosterPlayer] { bench + deep }
    var all: [RosterPlayer] { starters + bench + deep }

    func player(at slot: SlotID) -> RosterPlayer {
        switch slot {
        case .starter(let i): return starters[i]
        case .bench(let i): return bench[i]
        case .deep(let i): return deep[i]
        }
    }

    mutating func set(_ p: RosterPlayer, at slot: SlotID) {
        var p = p
        // An empty slot moved into a starter spot takes that spot's position.
        if p.isEmpty, case .starter(let i) = slot { p.position = Lineup.starterPositions[i] }
        switch slot {
        case .starter(let i): starters[i] = p
        case .bench(let i): bench[i] = p
        case .deep(let i): deep[i] = p
        }
    }

    func canPlace(_ p: RosterPlayer, at slot: SlotID) -> Bool {
        if case .starter(let i) = slot { return p.isEmpty || p.position == Lineup.starterPositions[i] }
        return true
    }

    /// Swaps two players. Returns false (and changes nothing) if a starter slot would get the wrong position.
    @discardableResult
    mutating func exchange(_ a: SlotID, _ b: SlotID) -> Bool {
        let pa = player(at: a)
        let pb = player(at: b)
        guard canPlace(pa, at: b), canPlace(pb, at: a) else { return false }
        set(pb, at: a)
        set(pa, at: b)
        return true
    }

    /// Drag-and-drop move.
    /// - Anything involving a starter spot swaps the two players (position rules apply).
    /// - Bench / deep bench moves re-order the nine subs: the dragged player is inserted at the
    ///   drop position and everyone between shifts one spot, so preferential order stays meaningful.
    @discardableResult
    mutating func move(from a: SlotID, to b: SlotID) -> Bool {
        guard a != b else { return false }
        if a.isStarter || b.isStarter { return exchange(a, b) }

        func subIndex(_ s: SlotID) -> Int? {
            switch s {
            case .bench(let i): return i
            case .deep(let i): return 3 + i
            case .starter: return nil
            }
        }
        guard let i = subIndex(a), let j = subIndex(b) else { return false }
        var list = subs
        let item = list.remove(at: i)
        list.insert(item, at: j)
        bench = Array(list[0..<3])
        deep = Array(list[3..<9])
        return true
    }

    mutating func mutatePlayer(id: UUID, _ change: (inout RosterPlayer) -> Void) {
        for i in starters.indices where starters[i].id == id { change(&starters[i]) }
        for i in bench.indices where bench[i].id == id { change(&bench[i]) }
        for i in deep.indices where deep[i].id == id { change(&deep[i]) }
    }

    /// Jon's W1 lineup from the 2026/27 sheet. Names use ESPN-style full names; matching is fuzzy anyway.
    static let seed = Lineup(
        teamName: "Brun and Gun",
        starters: [
            RosterPlayer(name: "Jalen Brunson", position: .G, teamHint: "NYK"),
            RosterPlayer(name: "Kyrie Irving", position: .G, teamHint: "DAL"),
            RosterPlayer(name: "Kevin Durant", position: .F, teamHint: "HOU"),
            RosterPlayer(name: "Cameron Boozer", position: .F, teamHint: "MEM"),
            RosterPlayer(name: "Zion Williamson", position: .C, teamHint: "NOP"),
        ],
        bench: [
            RosterPlayer(name: "Derrick White", position: .G, teamHint: "BOS"),
            RosterPlayer(name: "Caleb Wilson", position: .F, teamHint: "CHI"),
            RosterPlayer(name: "Naz Reid", position: .C, teamHint: "CHA"),
        ],
        deep: [
            RosterPlayer(name: "Cameron Johnson", position: .F, teamHint: "DEN"),
            RosterPlayer(name: "Keegan Murray", position: .F, teamHint: "SAC"),
            RosterPlayer(name: "Ayo Dosunmu", position: .G, teamHint: "MIN"),
            RosterPlayer(name: "Grayson Allen", position: .G, teamHint: "CHA"),
            RosterPlayer(name: "Mikel Brown Jr.", position: .G, teamHint: "BKN"),
            RosterPlayer(name: "Shaedon Sharpe", position: .F, teamHint: "POR"),
        ]
    )
}

// MARK: - Persistence

/// One lineup per league week, so past weeks keep the roster you actually had.
///
/// Stored as a dictionary keyed by the week's Tuesday ("yyyy-MM-dd", Eastern time). A week with no entry
/// of its own uses the most recent earlier entry, so a new entry only appears when you change something.
/// The current week and future weeks are editable. Past weeks are view-only.
@MainActor
final class LineupStore: ObservableObject {
    /// Sorts before every real date. Holds the lineup from before week history existed.
    static let baseKey = "0000-00-00"

    @Published private(set) var snapshots: [String: Lineup]
    @Published private(set) var viewedWeek: String

    private let fileURL: URL

    static func key(for weekStart: Date) -> String { ET.format("yyyy-MM-dd", weekStart) }
    static var currentWeekKey: String { key(for: ET.weekStart(containing: Date())) }

    private static func isValid(_ l: Lineup) -> Bool {
        l.starters.count == 5 && l.bench.count == 3 && l.deep.count == 6
    }

    /// `firstLaunch` is what a brand-new install starts with. It's Jon's Week 1 roster for his own phone;
    /// change it to `Lineup.blank()` before sharing the app so other managers start empty.
    init(
        fileURL: URL = Storage.url("lineups.json"),
        legacyURL: URL? = Storage.url("lineup.json"),
        firstLaunch: Lineup = Lineup.blank()
    ) {
        self.fileURL = fileURL
        self.viewedWeek = Self.currentWeekKey

        var loaded: [String: Lineup] = [:]
        var needsSave = false
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String: Lineup].self, from: data) {
            loaded = saved.filter { Self.isValid($0.value) }
        }
        if loaded.isEmpty {
            needsSave = true
            // First launch after this update: the single saved lineup becomes the starting point for every week.
            if let legacyURL,
               let data = try? Data(contentsOf: legacyURL),
               let old = try? JSONDecoder().decode(Lineup.self, from: data),
               Self.isValid(old) {
                loaded[Self.baseKey] = old
            } else {
                loaded[Self.baseKey] = firstLaunch
            }
        }
        if loaded[Self.baseKey] == nil, let first = loaded.keys.min() {
            loaded[Self.baseKey] = loaded[first]
        }
        self.snapshots = loaded
        if needsSave { save() }
    }

    // MARK: Which week

    func setViewedWeek(_ weekStart: Date) { viewedWeek = Self.key(for: weekStart) }

    /// Current and future weeks can be edited. Past weeks are locked.
    var isEditable: Bool { viewedWeek >= Self.currentWeekKey }

    /// The lineup in force for a week: its own entry, else the latest earlier one.
    func resolvedLineup(for key: String) -> Lineup {
        if let exact = snapshots[key] { return exact }
        if let earlier = snapshots.keys.filter({ $0 <= key }).max(), let l = snapshots[earlier] { return l }
        if let first = snapshots.keys.min(), let l = snapshots[first] { return l }
        return Lineup.blank()
    }

    /// The lineup for the week being viewed. Writing to it saves an entry for that week only.
    var lineup: Lineup {
        get { resolvedLineup(for: viewedWeek) }
        set {
            guard isEditable else { return }
            snapshots[viewedWeek] = newValue
            save()
        }
    }

    // MARK: Edits

    /// Matching a player to ESPN applies to every week, since it describes the player and not the week.
    func link(playerID: UUID, espnID: String) {
        for key in Array(snapshots.keys) {
            snapshots[key]?.mutatePlayer(id: playerID) { $0.espnID = espnID }
        }
        save()
    }

    func replace(slot: SlotID, with player: RosterPlayer) {
        var copy = lineup
        copy.set(player, at: slot)
        lineup = copy
    }

    func move(from a: SlotID, to b: SlotID) -> Bool {
        guard isEditable else { return false }
        var copy = lineup
        guard copy.move(from: a, to: b) else { return false }
        lineup = copy
        return true
    }

    func exchange(_ a: SlotID, _ b: SlotID) -> Bool {
        guard isEditable else { return false }
        var copy = lineup
        guard copy.exchange(a, b) else { return false }
        lineup = copy
        return true
    }

    enum AddResult {
        case added(SlotID)
        case duplicate
        case full
    }

    @discardableResult
    func add(_ player: RosterPlayer) -> AddResult {
        guard let id = player.espnID, !lineup.contains(espnID: id) else { return .duplicate }
        guard let slot = lineup.firstOpenSlot(for: player.position) else { return .full }
        replace(slot: slot, with: player)
        return .added(slot)
    }

    func remove(slot: SlotID) {
        replace(slot: slot, with: RosterPlayer.empty())
    }

    /// The team name belongs to you, not to a week, so renaming changes it everywhere.
    func rename(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        for key in Array(snapshots.keys) {
            snapshots[key]?.teamName = trimmed
        }
        save()
    }

    func clearAll() {
        lineup = Lineup.blank(teamName: lineup.teamName)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(snapshots) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
