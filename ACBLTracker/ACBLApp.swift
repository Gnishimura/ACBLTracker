import SwiftUI
import Combine

@main
struct ACBLApp: App {
    @StateObject private var lineupStore: LineupStore
    @StateObject private var directory: PlayerDirectory
    @StateObject private var week: WeekStore

    init() {
        let store = LineupStore()
        let dir = PlayerDirectory()
        _lineupStore = StateObject(wrappedValue: store)
        _directory = StateObject(wrappedValue: dir)
        _week = StateObject(wrappedValue: WeekStore(directory: dir, lineupStore: store))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(lineupStore)
                .environmentObject(directory)
                .environmentObject(week)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var week: WeekStore
    @EnvironmentObject var lineupStore: LineupStore
    @EnvironmentObject var directory: PlayerDirectory
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(Reminders.storageKey) private var remindersOn = true

    var body: some View {
        TabView {
            LineupView()
                .tabItem { Label("Lineup", systemImage: "list.number") }
            NightlyView()
                .tabItem { Label("Nightly", systemImage: "moon.stars") }
            GamesView()
                .tabItem { Label("Games", systemImage: "sportscourt") }
            FreeAgentsView()
                .tabItem { Label("Free Agents", systemImage: "person.badge.plus") }
            HistoryView()
                .tabItem { Label("History", systemImage: "chart.bar.fill") }
        }
        .task { await week.refresh() }
        .task { await Reminders.sync(enabled: remindersOn) }
        .task(id: rosterIDs) { await directory.loadSeasonPPG(for: rosterIDs) }
        .onChange(of: lineupStore.lineup) { _, _ in
            Task { await week.refresh() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await week.refresh() }
                Task { await directory.loadSeasonPPG(for: rosterIDs) }
            }
        }
        // While any of your players' games are live, poll once a minute.
        .task(id: week.hasLive) {
            guard week.hasLive else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { break }
                await week.refresh()
            }
        }
    }

    private var rosterIDs: [String] { lineupStore.lineup.all.compactMap(\.espnID) }
}
