import XCTest
@testable import ACBLTracker

final class ScoringEngineTests: XCTestCase {
    let rules = ScoringRules()

    // Jon's roster, in lineup order.
    private func lineup() -> Lineup { Lineup.seed }

    private func byName(_ l: Lineup, _ name: String) -> RosterPlayer {
        l.all.first { $0.name == name }!
    }

    /// Everyone plays and scores `default`, with overrides by name.
    private func avail(_ l: Lineup, default pts: Int = 10, _ overrides: [String: Availability] = [:]) -> [UUID: Availability] {
        var out: [UUID: Availability] = [:]
        for p in l.all { out[p.id] = overrides[p.name] ?? .played(pts) }
        return out
    }

    func testStarterBonusTiers() {
        XCTAssertEqual(rules.bonus(for: 29), 0)
        XCTAssertEqual(rules.bonus(for: 30), 2)
        XCTAssertEqual(rules.bonus(for: 39), 2)
        XCTAssertEqual(rules.bonus(for: 40), 5)
        XCTAssertEqual(rules.bonus(for: 52), 5)
    }

    func testStarterGetsFullPointsAndBonus() {
        let l = lineup()
        let a = avail(l, ["Jalen Brunson": .played(34)])
        let r = ScoringEngine.resolve(lineup: l, availability: a, rules: rules)
        let b = r[byName(l, "Jalen Brunson").id]!
        XCTAssertEqual(b.role, .starter)
        XCTAssertEqual(b.countedPoints, 34)
        XCTAssertEqual(b.bonus, 2)
        XCTAssertEqual(b.total, 36)
    }

    func testPlayingSubsGetHalfRoundedUpAndNoBonus() {
        let l = lineup()
        let a = avail(l, ["Derrick White": .played(17), "Caleb Wilson": .played(31), "Naz Reid": .played(9)])
        let r = ScoringEngine.resolve(lineup: l, availability: a, rules: rules)
        XCTAssertEqual(r[byName(l, "Derrick White").id]!.total, 9)   // 17 -> 9
        XCTAssertEqual(r[byName(l, "Caleb Wilson").id]!.total, 16)   // 31 -> 16, no bonus
        XCTAssertEqual(r[byName(l, "Naz Reid").id]!.total, 5)        // 9 -> 5
    }

    func testDeepBenchDoesNotCountWhenEveryoneIsActive() {
        let l = lineup()
        let r = ScoringEngine.resolve(lineup: l, availability: avail(l), rules: rules)
        XCTAssertEqual(r[byName(l, "Cameron Johnson").id]!.role, .notCounted)
        XCTAssertEqual(r[byName(l, "Cameron Johnson").id]!.total, 0)
    }

    func testDNPStarterIsReplacedBySamePositionSub() {
        // Brunson (G) sits. White (G, first bench) steps in at full value; bench shifts up.
        let l = lineup()
        let a = avail(l, ["Jalen Brunson": .dnp, "Derrick White": .played(32)])
        let r = ScoringEngine.resolve(lineup: l, availability: a, rules: rules)

        let white = r[byName(l, "Derrick White").id]!
        XCTAssertEqual(white.role, .promoted)
        XCTAssertEqual(white.countedPoints, 32)
        XCTAssertEqual(white.bonus, 2)

        // Remaining subs in order: Wilson, Reid, Johnson are the three playing subs now.
        XCTAssertEqual(r[byName(l, "Caleb Wilson").id]!.role, .playingSub)
        XCTAssertEqual(r[byName(l, "Naz Reid").id]!.role, .playingSub)
        XCTAssertEqual(r[byName(l, "Cameron Johnson").id]!.role, .playingSub)
        XCTAssertEqual(r[byName(l, "Keegan Murray").id]!.role, .notCounted)
    }

    func testReplacementSkipsSubsWhoAlsoSit() {
        // Brunson and White both out: next guard in order is Dosunmu.
        let l = lineup()
        let a = avail(l, ["Jalen Brunson": .dnp, "Derrick White": .dnp])
        let r = ScoringEngine.resolve(lineup: l, availability: a, rules: rules)
        XCTAssertEqual(r[byName(l, "Ayo Dosunmu").id]!.role, .promoted)
        XCTAssertEqual(r[byName(l, "Derrick White").id]!.role, .notCounted)
    }

    func testNoEligibleReplacementMeansSlotScoresZero() {
        let l = lineup()
        // Zion is the only C starter; Naz Reid is the only other C. Both out.
        let a = avail(l, ["Zion Williamson": .dnp, "Naz Reid": .dnp])
        let r = ScoringEngine.resolve(lineup: l, availability: a, rules: rules)
        XCTAssertEqual(r[byName(l, "Zion Williamson").id]!.total, 0)
        XCTAssertFalse(r.values.contains { $0.role == .promoted })
    }

    func testDNPBenchPlayerPassesPlayingSubSpotDown() {
        let l = lineup()
        let a = avail(l, ["Caleb Wilson": .dnp])
        let r = ScoringEngine.resolve(lineup: l, availability: a, rules: rules)
        XCTAssertEqual(r[byName(l, "Derrick White").id]!.role, .playingSub)
        XCTAssertEqual(r[byName(l, "Naz Reid").id]!.role, .playingSub)
        XCTAssertEqual(r[byName(l, "Cameron Johnson").id]!.role, .playingSub)
    }

    func testPendingPlayersCountProvisionally() {
        let l = lineup()
        var a = avail(l)
        a[byName(l, "Kevin Durant").id] = .pending
        let r = ScoringEngine.resolve(lineup: l, availability: a, rules: rules)
        XCTAssertEqual(r[byName(l, "Kevin Durant").id]!.role, .starter)
        XCTAssertEqual(r[byName(l, "Kevin Durant").id]!.total, 0)
    }

    func testPositionLockOnStarterSlots() {
        var l = lineup()
        // Guard into a forward slot is rejected.
        XCTAssertFalse(l.exchange(.starter(0), .starter(2)))
        // Guard <-> guard is fine; bench swaps are unrestricted.
        XCTAssertTrue(l.exchange(.starter(0), .starter(1)))
        XCTAssertTrue(l.exchange(.starter(0), .bench(0)))
    }

    func testNameMatching() {
        XCTAssertEqual("Alperen Şengün".normalizedName, "alperen sengun")
        XCTAssertEqual("Mikel Brown Jr.".normalizedName, "mikel brown")
        XCTAssertEqual(levenshtein("jeremi grant", "jerami grant"), 1)
    }

    func testBlankRosterAndOpenSlots() {
        var l = Lineup.blank()
        XCTAssertTrue(l.isEmpty)
        XCTAssertEqual(l.firstOpenSlot(for: .C), .starter(4))
        XCTAssertEqual(l.firstOpenSlot(for: .G), .starter(0))
        l.set(RosterPlayer(name: "A", position: .G, teamHint: "X", espnID: "1"), at: .starter(0))
        l.set(RosterPlayer(name: "B", position: .G, teamHint: "X", espnID: "2"), at: .starter(1))
        XCTAssertEqual(l.firstOpenSlot(for: .G), .bench(0))      // both G starter spots full
        XCTAssertTrue(l.contains(espnID: "2"))
    }

    func testEmptySlotsScoreZeroAndNeverGetPromoted() {
        var l = Lineup.blank()
        let g = RosterPlayer(name: "G1", position: .G, teamHint: "X", espnID: "1")
        l.set(g, at: .starter(0))
        var a: [UUID: Availability] = [:]
        for p in l.all { a[p.id] = p.isEmpty ? .dnp : .played(35) }
        let r = ScoringEngine.resolve(lineup: l, availability: a, rules: rules)
        XCTAssertEqual(r[g.id]!.total, 37)                       // 35 + 2 bonus
        XCTAssertEqual(r.values.filter { $0.isCounted }.count, 1)
    }

    func testEmptySlotCanSwapIntoStarterSpot() {
        var l = Lineup.blank()
        l.set(RosterPlayer(name: "B", position: .F, teamHint: "X", espnID: "9"), at: .bench(0))
        XCTAssertTrue(l.exchange(.bench(0), .starter(2)))        // F into an F spot
        XCTAssertEqual(l.starters[2].name, "B")
        XCTAssertTrue(l.exchange(.starter(0), .bench(1)))        // empty <-> empty is fine
    }

    func testDragMoveReordersSubsAndSwapsWithStarters() {
        var l = Lineup.seed
        // Deep bench #1 dropped on bench #1: inserted at the top, everyone else shifts down.
        XCTAssertTrue(l.move(from: .deep(0), to: .bench(0)))
        XCTAssertEqual(l.bench.map(\.name), ["Cameron Johnson", "Derrick White", "Caleb Wilson"])
        XCTAssertEqual(l.deep.first?.name, "Naz Reid")
        // A forward can't take a guard's starter spot.
        XCTAssertFalse(l.move(from: .bench(0), to: .starter(0)))
        // A guard can: he and the starter swap places.
        XCTAssertTrue(l.move(from: .bench(1), to: .starter(0)))
        XCTAssertEqual(l.starters[0].name, "Derrick White")
        XCTAssertEqual(l.bench[1].name, "Jalen Brunson")
    }

    func testSlotPayloadRoundTrip() {
        for slot in [SlotID.starter(4), .bench(2), .deep(5)] {
            XCTAssertEqual(SlotID(payload: slot.payload), slot)
        }
        XCTAssertNil(SlotID(payload: "starter-9"))
        XCTAssertNil(SlotID(payload: "junk"))
    }
    // MARK: - Week history

    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("acbl-\(UUID().uuidString)-\(name)")
    }

    private func player(_ name: String, _ pos: Position, _ id: String) -> RosterPlayer {
        RosterPlayer(name: name, position: pos, teamHint: "X", espnID: id)
    }

    @MainActor
    func testEditsStayInTheirWeekAndCarryForward() {
        let store = LineupStore(fileURL: tempURL("a.json"), legacyURL: nil, firstLaunch: Lineup.blank())
        let w0 = ET.weekStart(containing: Date())
        let w1 = ET.addDays(7, to: w0)
        let w2 = ET.addDays(14, to: w0)

        store.setViewedWeek(w1)
        store.add(player("A", .G, "1"))
        XCTAssertTrue(store.lineup.contains(espnID: "1"))

        store.setViewedWeek(w2)                              // no entry of its own: carries week 1 forward
        XCTAssertTrue(store.lineup.contains(espnID: "1"))
        store.remove(slot: .starter(0))
        XCTAssertFalse(store.lineup.contains(espnID: "1"))

        store.setViewedWeek(w1)                              // week 1 untouched by the week 2 edit
        XCTAssertTrue(store.lineup.contains(espnID: "1"))

        store.setViewedWeek(w0)                              // earlier weeks keep the older lineup
        XCTAssertFalse(store.lineup.contains(espnID: "1"))
    }

    @MainActor
    func testPastWeeksAreLocked() {
        let store = LineupStore(fileURL: tempURL("b.json"), legacyURL: nil, firstLaunch: Lineup.blank())
        store.setViewedWeek(ET.addDays(-7, to: ET.weekStart(containing: Date())))
        XCTAssertFalse(store.isEditable)
        store.add(player("A", .G, "1"))
        XCTAssertTrue(store.lineup.isEmpty)
        XCTAssertFalse(store.move(from: .bench(0), to: .bench(1)))
    }

    @MainActor
    func testRenameAppliesToEveryWeekAndLinkReachesPastWeeks() {
        let url = tempURL("c.json")
        let store = LineupStore(fileURL: url, legacyURL: nil, firstLaunch: Lineup.blank())
        let w0 = ET.weekStart(containing: Date())
        let w1 = ET.addDays(7, to: w0)

        let unmatched = RosterPlayer(name: "Z", position: .G, teamHint: "X", espnID: nil)
        store.setViewedWeek(w0)
        store.replace(slot: .starter(0), with: unmatched)
        store.setViewedWeek(w1)
        store.remove(slot: .starter(1))                       // week 1 now has its own entry
        store.rename("Renamed")
        store.link(playerID: unmatched.id, espnID: "77")

        for week in [w0, w1] {
            store.setViewedWeek(week)
            XCTAssertEqual(store.lineup.teamName, "Renamed")
            XCTAssertEqual(store.lineup.starters[0].espnID, "77")
        }
    }

    @MainActor
    func testHistorySurvivesRelaunchAndMigratesOldFile() throws {
        // Old single-lineup file becomes the starting lineup for every week.
        let legacy = tempURL("lineup.json")
        try JSONEncoder().encode(Lineup.seed).write(to: legacy)
        let url = tempURL("d.json")
        let first = LineupStore(fileURL: url, legacyURL: legacy)
        XCTAssertEqual(first.lineup, Lineup.seed)

        let w1 = ET.addDays(7, to: ET.weekStart(containing: Date()))
        first.setViewedWeek(w1)
        first.remove(slot: .starter(0))

        let second = LineupStore(fileURL: url, legacyURL: legacy)
        second.setViewedWeek(w1)
        XCTAssertTrue(second.lineup.starters[0].isEmpty)
        second.setViewedWeek(ET.addDays(-7, to: ET.weekStart(containing: Date())))
        XCTAssertEqual(second.lineup, Lineup.seed)
    }

    func testFinishedWeekRoundTripsThroughJSON() throws {
        let id = UUID()
        let line = GameLine(eventID: "e1", date: Date(timeIntervalSince1970: 1_800_000_000), opponent: "vs BOS",
                            state: .final, statusText: "Final", points: 34)
        let result = PlayerGameResult(role: .starter, availability: .played(34), countedPoints: 34, bonus: 2)
        let week = WeekResults(lines: [id: [line, nil]], perGame: [[id: result], [:]])
        let data = try JSONEncoder().encode(["2026-10-20": week])
        let back = try JSONDecoder().decode([String: WeekResults].self, from: data)["2026-10-20"]!
        XCTAssertEqual(back.weekTotal, 36)
        XCTAssertEqual(back.line(for: id, game: 0), line)
        XCTAssertNil(back.line(for: id, game: 1))
    }

    @MainActor
    func testLeagueWeekNumbers() {
        let w1 = WeekStore.seasonStart
        XCTAssertEqual(ET.format("yyyy-MM-dd EEE", w1), "2026-10-20 Tue")
        XCTAssertEqual(WeekStore.weekNumber(for: w1), 1)
        XCTAssertEqual(WeekStore.weekNumber(for: ET.addDays(7, to: w1)), 2)
        XCTAssertEqual(WeekStore.weekNumber(for: ET.addDays(7 * 25, to: w1)), 26)   // across the November DST change
        XCTAssertEqual(WeekStore.weekNumber(for: ET.addDays(-7, to: w1)), 0)
    }

    func testInjurySummaryText() {
        XCTAssertEqual(Injury(status: "Out", part: "Knee", detail: "Sprain").summary, "Out - Knee sprain")
        XCTAssertEqual(Injury(status: "Day-To-Day", part: "Illness", detail: "Illness").summary, "Day-To-Day - Illness")
        XCTAssertEqual(Injury(status: "Out", part: nil, detail: "Rest").summary, "Out - Rest")
        XCTAssertEqual(Injury(status: "Out", part: nil, detail: nil).summary, "Out")
    }

    func testInjuryDrillDownFields() {
        // Nothing beyond the summary line: no drill-down.
        XCTAssertFalse(Injury(status: "Out", part: "Knee", detail: "Sprain").hasDrillDown)

        // Prefers the long blurb, falls back to the short one, ignores blank text.
        XCTAssertEqual(Injury(status: "Out", part: nil, detail: nil, shortComment: "Short", longComment: "Long").blurb, "Long")
        XCTAssertEqual(Injury(status: "Out", part: nil, detail: nil, shortComment: "Short", longComment: "  ").blurb, "Short")
        XCTAssertTrue(Injury(status: "Out", part: nil, detail: nil, shortComment: "Short").hasDrillDown)

        // Side shows up in the body-part text only when ESPN actually specifies one.
        XCTAssertEqual(Injury(status: "Out", part: "Knee", detail: nil, side: "Left").bodyPartText, "Left knee")
        XCTAssertEqual(Injury(status: "Out", part: "Knee", detail: nil, side: "Not Specified").bodyPartText, "Knee")
    }

    func testInjuryDateParsing() {
        XCTAssertNotNil(Injury.parseDate("2026-10-24T18:32:00Z"))
        XCTAssertNotNil(Injury.parseDate("2026-10-24T18:32Z"))
        XCTAssertNotNil(Injury.parseDate("2026-11-01"))
        XCTAssertNil(Injury.parseDate(nil))
        XCTAssertNil(Injury.parseDate(""))
    }
}
