import XCTest
@testable import ACBLTracker

final class LineupEmailTests: XCTestCase {
    /// Uses the hint on the player as the team, the way an unmatched player would print.
    private func hint(_ p: RosterPlayer) -> String { p.teamHint }

    /// Matches the Week 1 email sent to the league (the one difference: it was typed "Cam Johnson").
    func testBodyMatchesLeagueFormat() {
        let body = LineupEmail.body(lineup: .seed, managerName: "Jon", teamAbbr: hint)
        let expected = """
        Brun and Gun (Jon)
        G - Jalen Brunson (NYK)
        G - Kyrie Irving (DAL)
        F - Kevin Durant (HOU)
        F - Cameron Boozer (MEM)
        C - Zion Williamson (NOP)

        G - Derrick White (BOS)
        F - Caleb Wilson (CHI)
        C - Naz Reid (CHA)

        F - Cameron Johnson (DEN)
        F - Keegan Murray (SAC)
        G - Ayo Dosunmu (MIN)
        G - Grayson Allen (CHA)
        G - Mikel Brown Jr. (BKN)
        F - Shaedon Sharpe (POR)
        """
        XCTAssertEqual(body, expected)
    }

    func testBlankNameDropsParentheses() {
        let body = LineupEmail.body(lineup: .seed, managerName: "  ", teamAbbr: hint)
        XCTAssertEqual(body.components(separatedBy: "\n").first, "Brun and Gun")
    }

    func testReorderingChangesTheEmail() {
        var l = Lineup.seed
        XCTAssertTrue(l.move(from: .deep(0), to: .bench(0)))   // Cam Johnson jumps to the top of the bench
        let lines = LineupEmail.body(lineup: l, managerName: "Jon", teamAbbr: hint).components(separatedBy: "\n")
        XCTAssertEqual(lines[7], "F - Cameron Johnson (DEN)")
        XCTAssertEqual(lines[8], "G - Derrick White (BOS)")
    }

    func testEmptySlotsAreSpelledOut() {
        var l = Lineup.seed
        l.set(.empty(), at: .starter(2))
        l.set(.empty(), at: .deep(5))
        XCTAssertEqual(LineupEmail.emptySlotCount(l), 2)
        let lines = LineupEmail.body(lineup: l, managerName: "", teamAbbr: hint).components(separatedBy: "\n")
        XCTAssertEqual(lines[3], "F - (empty)")      // starter slot keeps its position
        XCTAssertEqual(lines.last, "(empty)")        // bench slots have none
    }

    func testPlayerWithNoTeamHasNoParentheses() {
        var l = Lineup.blank(teamName: "T")
        l.set(RosterPlayer(name: "Kennedy Chandler", position: .G, teamHint: ""), at: .starter(0))
        let lines = LineupEmail.body(lineup: l, managerName: "", teamAbbr: hint).components(separatedBy: "\n")
        XCTAssertEqual(lines[1], "G - Kennedy Chandler")
    }

    func testTeamCodesUseLeagueStyle() {
        XCTAssertEqual(LineupEmail.teamCode("NY"), "NYK")
        XCTAssertEqual(LineupEmail.teamCode("gs"), "GSW")
        XCTAssertEqual(LineupEmail.teamCode("UTAH"), "UTA")
        XCTAssertEqual(LineupEmail.teamCode("WSH"), "WAS")
        XCTAssertEqual(LineupEmail.teamCode("NYK"), "NYK")   // already league style
        XCTAssertEqual(LineupEmail.teamCode("OKC"), "OKC")
    }

    func testAddressParsing() {
        XCTAssertEqual(
            LineupEmail.addresses("a@x.com, b@y.com;c@z.com\n d@w.com notanemail"),
            ["a@x.com", "b@y.com", "c@z.com", "d@w.com"]
        )
        XCTAssertEqual(LineupEmail.addresses(""), [])
    }

    func testGmailURLEncodesNewlinesAndSpecials() throws {
        let url = try XCTUnwrap(LineupEmail.gmailURL(
            to: ["a@x.com", "b@y.com"], cc: [], subject: "Week 2 lineups", body: "Brun & Gun (Jon)\nG - Luka Dončić"
        ))
        let s = url.absoluteString
        XCTAssertTrue(s.hasPrefix("googlegmail:///co?to=a%40x.com,b%40y.com&subject=Week%202%20lineups&body="))
        XCTAssertTrue(s.hasSuffix("Brun%20%26%20Gun%20%28Jon%29%0AG%20-%20Luka%20Don%C4%8Di%C4%87"))
        XCTAssertFalse(s.contains("cc="))
        XCTAssertFalse(s.contains("\n"))
    }

    func testMailtoFallback() throws {
        let url = try XCTUnwrap(LineupEmail.mailtoURL(to: ["a@x.com"], cc: ["b@y.com"], subject: "S", body: "x\ny"))
        XCTAssertEqual(url.absoluteString, "mailto:a%40x.com?cc=b%40y.com&subject=S&body=x%0Ay")
    }

    func testSubject() {
        XCTAssertEqual(LineupEmail.subject(weekLabel: "Week 2"), "Week 2 lineups")
    }
}
