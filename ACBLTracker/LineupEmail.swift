import SwiftUI
import UIKit

// Drafts the weekly lineup email in the Gmail app, in the format the league already uses:
//
//   Brun and Gun (Jon)
//   G - Jalen Brunson (NYK)
//   ...five starters, blank line, three bench, blank line, six deep bench
//
// Nothing is sent from the app. It opens a prefilled draft and you press send in Gmail.

enum LineupEmail {
    /// UserDefaults keys. Recipients are typed in by each manager, never baked into the code.
    static let toKey = "lineupEmailTo"
    static let ccKey = "lineupEmailCc"
    static let nameKey = "lineupEmailName"
    static let promptKey = "lineupEmailPromptAfterEdit"

    // MARK: Text

    /// ESPN's short codes -> the three-letter codes league emails use.
    private static let codes = [
        "NY": "NYK", "GS": "GSW", "NO": "NOP", "SA": "SAS", "WSH": "WAS", "UTAH": "UTA", "PHO": "PHX",
    ]

    static func teamCode(_ abbr: String) -> String {
        let u = abbr.trimmingCharacters(in: .whitespaces).uppercased()
        return codes[u] ?? u
    }

    /// "Week 2 lineups"
    static func subject(weekLabel: String) -> String { "\(weekLabel) lineups" }

    /// `teamAbbr` returns the team to print for a player. Pass the live ESPN team so trades are picked up.
    static func body(lineup: Lineup, managerName: String, teamAbbr: (RosterPlayer) -> String) -> String {
        func line(_ p: RosterPlayer, _ slotPosition: Position?) -> String {
            if p.isEmpty { return slotPosition.map { "\($0.rawValue) - (empty)" } ?? "(empty)" }
            let code = teamCode(teamAbbr(p))
            let team = code.isEmpty ? "" : " (\(code))"
            return "\(p.position.rawValue) - \(p.name)\(team)"
        }

        let name = managerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let header = name.isEmpty ? lineup.teamName : "\(lineup.teamName) (\(name))"
        let starters = lineup.starters.enumerated().map { line($1, Lineup.starterPositions[$0]) }
        let bench = lineup.bench.map { line($0, nil) }
        let deep = lineup.deep.map { line($0, nil) }
        return ([header] + starters + [""] + bench + [""] + deep).joined(separator: "\n")
    }

    static func emptySlotCount(_ lineup: Lineup) -> Int { lineup.all.filter(\.isEmpty).count }

    /// Splits "a@x.com, b@y.com; c@z.com" into clean addresses.
    static func addresses(_ raw: String) -> [String] {
        raw.split(whereSeparator: { ",; \n\t".contains($0) })
            .map { String($0) }
            .filter { $0.contains("@") }
    }

    // MARK: Links

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static func query(to: [String], cc: [String], subject: String, body: String) -> String {
        var parts: [String] = []
        if !to.isEmpty { parts.append("to=" + to.map(enc).joined(separator: ",")) }
        if !cc.isEmpty { parts.append("cc=" + cc.map(enc).joined(separator: ",")) }
        parts.append("subject=" + enc(subject))
        parts.append("body=" + enc(body))
        return parts.joined(separator: "&")
    }

    /// Opens a compose window in the Gmail app. Gmail's URL scheme takes to, cc, subject and body.
    static func gmailURL(to: [String], cc: [String], subject: String, body: String) -> URL? {
        URL(string: "googlegmail:///co?" + query(to: to, cc: cc, subject: subject, body: body))
    }

    /// Fallback for phones without Gmail: opens whatever mail app is the default.
    static func mailtoURL(to: [String], cc: [String], subject: String, body: String) -> URL? {
        let recipients = to.map(enc).joined(separator: ",")
        var parts: [String] = []
        if !cc.isEmpty { parts.append("cc=" + cc.map(enc).joined(separator: ",")) }
        parts.append("subject=" + enc(subject))
        parts.append("body=" + enc(body))
        return URL(string: "mailto:\(recipients)?" + parts.joined(separator: "&"))
    }
}

/// Shown after you tap Done on a changed lineup, or from the ... menu. Check the email, then open it in Gmail.
struct LineupEmailSheet: View {
    @EnvironmentObject var lineupStore: LineupStore
    @EnvironmentObject var week: WeekStore
    @EnvironmentObject var directory: PlayerDirectory
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @AppStorage(LineupEmail.toKey) private var to = ""
    @AppStorage(LineupEmail.ccKey) private var cc = ""
    @AppStorage(LineupEmail.nameKey) private var managerName = ""
    @AppStorage(LineupEmail.promptKey) private var promptAfterEdit = true
    @State private var copied = false

    private var subject: String { LineupEmail.subject(weekLabel: week.weekLabel) }

    private var emailBody: String {
        LineupEmail.body(lineup: lineupStore.lineup, managerName: managerName) { directory.display(for: $0).teamAbbr }
    }

    private var emptyCount: Int { LineupEmail.emptySlotCount(lineupStore.lineup) }

    private var headerPreview: String {
        let team = lineupStore.lineup.teamName
        let name = managerName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? team : "\(team) (\(name))"
    }

    private func addressField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text, axis: .vertical)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    addressField("To (commissioner or whole league)", text: $to)
                    addressField("Cc", text: $cc)
                } header: {
                    Text("Send to")
                } footer: {
                    Text("Separate addresses with commas. Saved on this phone.")
                }

                Section {
                    TextField("Your name, e.g. Jon", text: $managerName)
                } header: {
                    Text("Name after your team")
                } footer: {
                    Text("First line of the email: \(headerPreview). Leave the name blank to skip it.")
                }

                Section {
                    Text(subject).font(.subheadline.weight(.semibold))
                    Text(emailBody)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                } header: {
                    Text("Draft")
                } footer: {
                    Text("\(week.weekLabel) lineup due \(Deadline.label(Deadline.lineupDeadline(weekStart: week.weekStart))).")
                }

                if emptyCount > 0 {
                    Section {
                        Label("\(emptyCount) empty slot\(emptyCount == 1 ? "" : "s") in this lineup.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.subheadline)
                    }
                }

                Section {
                    Button { draft() } label: {
                        Label("Draft in Gmail", systemImage: "envelope.fill").bold()
                    }
                    Button { copy() } label: {
                        Label(copied ? "Copied" : "Copy text", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                } footer: {
                    Text("Opens a draft in the Gmail app, or your default mail app if Gmail isn't installed. Nothing is sent until you press send there.")
                }

                Section {
                    Toggle("Offer this after I edit my lineup", isOn: $promptAfterEdit)
                }
            }
            .navigationTitle("Email lineup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Not now") { dismiss() } }
            }
        }
        .presentationDetents([.large])
    }

    private func draft() {
        let toList = LineupEmail.addresses(to)
        let ccList = LineupEmail.addresses(cc)
        guard let gmail = LineupEmail.gmailURL(to: toList, cc: ccList, subject: subject, body: emailBody) else { return }
        openURL(gmail) { accepted in
            if accepted {
                dismiss()
            } else if let mailto = LineupEmail.mailtoURL(to: toList, cc: ccList, subject: subject, body: emailBody) {
                openURL(mailto)
                dismiss()
            }
        }
    }

    private func copy() {
        UIPasteboard.general.string = emailBody
        copied = true
    }
}
