import SwiftUI

/// Replace the player in a slot with any NBA player from the ESPN directory.
/// Positions are league-assigned, so you choose G/F/C yourself (defaults to ESPN's listing).
struct PlayerPickerView: View {
    let slot: SlotID

    @EnvironmentObject var directory: PlayerDirectory
    @EnvironmentObject var lineupStore: LineupStore
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var chosen: DirectoryPlayer?
    @State private var position: Position = .G

    private var lockedPosition: Position? {
        if case .starter(let i) = slot { return Lineup.starterPositions[i] }
        return nil
    }

    var body: some View {
        NavigationStack {
            List {
                if let chosen {
                    Section("Selected") {
                        pickerRow(chosen)
                        if let locked = lockedPosition {
                            LabeledContent("League position", value: locked.rawValue)
                        } else {
                            Picker("League position", selection: $position) {
                                ForEach(Position.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }
                        Button("Put \(chosen.name) in this slot") { confirm(chosen) }
                            .bold()
                    }
                }
                Section(query.normalizedName.count < 2 ? "Type at least 2 letters" : "Results") {
                    ForEach(directory.search(query)) { p in
                        Button {
                            chosen = p
                            position = lockedPosition ?? Position.fromESPN(p.position)
                        } label: {
                            pickerRow(p)
                        }
                        .buttonStyle(.plain)
                        .disabled(lineupStore.lineup.contains(espnID: p.id))
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search NBA players")
            .navigationTitle(lineupStore.lineup.player(at: slot).isEmpty ? "Add player" : "Replace player")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func pickerRow(_ p: DirectoryPlayer) -> some View {
        let display = directory.display(for: p)
        return HStack(spacing: 10) {
            HeadshotView(url: display.headshot, size: 40, teamColor: display.teamColor)
            Text(p.name).font(.subheadline.weight(.semibold))
            Spacer()
            TeamTag(display: display)
        }
    }

    private func confirm(_ p: DirectoryPlayer) {
        let pos = lockedPosition ?? position
        let player = RosterPlayer(name: p.name, position: pos, teamHint: p.teamAbbr, espnID: p.id)
        lineupStore.replace(slot: slot, with: player)
        dismiss()
    }
}
