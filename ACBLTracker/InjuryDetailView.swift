import SwiftUI

/// Drill-down from a player's detail page: everything ESPN's injury report says about him.
/// Every row is optional; ESPN fills these in unevenly, so a row only shows when there's data behind it.
struct InjuryDetailView: View {
    let playerName: String
    let injury: Injury

    var body: some View {
        List {
            Section {
                row("Status", injury.status, color: .red)
                if let part = injury.bodyPartText { row("Injury", part) }
                if let detail = injury.detail, !detail.isEmpty,
                   detail.lowercased() != injury.part?.lowercased() {
                    row("Type", detail)
                }
                if let returnDate = injury.returnDate {
                    row("Estimated return", returnDate.formatted(.dateTime.month(.abbreviated).day().year()))
                }
                if let reported = injury.reportedAt {
                    row("Updated", reported.formatted(.relative(presentation: .named)))
                }
            }

            if let blurb = injury.blurb {
                Section("LATEST") {
                    Text(blurb).font(.body)
                }
            }

            Section {
            } footer: {
                Text("Source: ESPN injury report. Refreshed every few minutes while the app is open.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(playerName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ label: String, _ value: String, color: Color = .secondary) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(color).multilineTextAlignment(.trailing)
        }
    }
}
