import SwiftUI
import UserNotifications

// USACBL Rules B.3 and A.3: lineups are due before 1 pm Pacific on the Tuesday that starts the week,
// and free agent requests are due Sunday at 9 pm Pacific.

@MainActor
enum Deadline {
    static let pacific = TimeZone(identifier: "America/Los_Angeles")!

    private static var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = pacific
        return c
    }

    /// 1 pm Pacific on the Tuesday that starts the league week.
    /// (If no NBA games are played that Tuesday the league pushes the deadline to the first game day. That's rare
    /// and the app doesn't model it, so check the league email in those weeks.)
    static func lineupDeadline(weekStart: Date) -> Date {
        let e = ET.cal.dateComponents([.year, .month, .day], from: weekStart)
        var c = DateComponents()
        c.year = e.year
        c.month = e.month
        c.day = e.day
        c.hour = 13
        c.minute = 0
        return cal.date(from: c) ?? weekStart
    }

    /// The next lineup deadline after `now`, and the league week it belongs to.
    static func next(after now: Date = Date()) -> (weekNumber: Int, date: Date) {
        let thisWeek = ET.weekStart(containing: now)
        let thisDeadline = lineupDeadline(weekStart: thisWeek)
        if now < thisDeadline { return (WeekStore.weekNumber(for: thisWeek), thisDeadline) }
        let nextStart = ET.addDays(7, to: thisWeek)
        return (WeekStore.weekNumber(for: nextStart), lineupDeadline(weekStart: nextStart))
    }

    /// "Tue Oct 27, 1:00 PM PT"
    static func label(_ d: Date) -> String {
        let f = DateFormatter()
        f.timeZone = pacific
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM d, h:mm a"
        return f.string(from: d) + " PT"
    }
}

/// One line on the Lineup tab: "Week 2 lineup due in 4d 18h".
struct DeadlineRow: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let next = Deadline.next(after: context.date)
            let secs = next.date.timeIntervalSince(context.date)
            let tint = tintColor(secs)
            HStack(spacing: 6) {
                Image(systemName: "clock").font(.caption).foregroundStyle(tint)
                Text("Week \(next.weekNumber) lineup due \(relative(secs))")
                    .font(.caption.weight(.semibold)).foregroundStyle(tint)
                Spacer()
                Text(Deadline.label(next.date)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func relative(_ secs: TimeInterval) -> String {
        let total = max(Int(secs / 60), 0)
        let d = total / 1440
        let h = (total % 1440) / 60
        let m = total % 60
        if d > 0 { return "in \(d)d \(h)h" }
        if h > 0 { return "in \(h)h \(m)m" }
        return "in \(m)m"
    }

    private func tintColor(_ secs: TimeInterval) -> Color {
        if secs < 2 * 3600 { return .red }
        if secs < 24 * 3600 { return .orange }
        return .secondary
    }
}

/// Weekly local notifications. They're scheduled on the phone, so they work without the app open
/// and without a paid developer account.
@MainActor
enum Reminders {
    static let storageKey = "lineupRemindersOn"

    private static let ids = ["acbl-lineup-morning", "acbl-lineup-hour", "acbl-fa-sunday"]

    static func sync(enabled: Bool) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ids)
        guard enabled else { return }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }

        // weekday: Sunday = 1, Tuesday = 3. Times are Pacific whatever the phone's zone is.
        await add(center, ids[0], weekday: 3, hour: 9,
                  title: "Lineup due today", body: "Set your USACBL lineup before 1 pm PT.")
        await add(center, ids[1], weekday: 3, hour: 12,
                  title: "Lineup due in 1 hour", body: "Deadline is 1 pm PT. Check your starters and bench order.")
        await add(center, ids[2], weekday: 1, hour: 18,
                  title: "Free agent requests due tonight", body: "Email the commissioner by 9 pm PT if you want a free agent.")
    }

    private static func add(
        _ center: UNUserNotificationCenter, _ id: String, weekday: Int, hour: Int, title: String, body: String
    ) async {
        var c = DateComponents()
        c.timeZone = Deadline.pacific
        c.weekday = weekday
        c.hour = hour
        c.minute = 0
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: c, repeats: true)
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}
