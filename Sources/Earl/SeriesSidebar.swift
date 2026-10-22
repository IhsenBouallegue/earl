import SwiftUI

// S-2 polish: the meetings that recur, bundled in the sidebar. The day list
// shows each Daily on its own; this section shows that they belong together,
// newest series first, and opens the series page (the brief when one is coming).

struct SidebarSeriesSection: View {
    @EnvironmentObject private var state: AppState
    let select: (SidebarItem) -> Void

    @State private var showAll = false
    static let shown = 4

    /// Series with two or more meetings, the most recently met first.
    static func series(_ meetings: [Meeting]) -> [(key: String, name: String, count: Int)] {
        MeetingSeries.groups(meetings)
            .sorted { ($0.value.first?.info.startedAt ?? .distantPast) > ($1.value.first?.info.startedAt ?? .distantPast) }
            .map { (key: $0.key, name: MeetingSeries.displayName($0.value), count: $0.value.count) }
    }

    var body: some View {
        let all = Self.series(state.meetings)
        if !all.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SidebarSectionTitle(title: "Series")
                // The heading sets them apart; the rows differ from meetings by
                // ending in when they meet, where meetings start with a time.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(showAll ? all : Array(all.prefix(Self.shown)), id: \.key) { series in
                        SeriesShelfRow(key: series.key, name: series.name, count: series.count,
                                       calendar: state.calendar, select: select)
                    }
                    if all.count > Self.shown {
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) { showAll.toggle() }
                        } label: {
                            Text(showAll ? "Show fewer" : "Show all \(all.count)")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Paper.inkMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .frame(height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// A series on the shelf: its name, and when it meets next today or when it
/// last met, so the row says something the day list doesn't.
private struct SeriesShelfRow: View {
    @EnvironmentObject private var state: AppState
    let key: String
    let name: String
    let count: Int
    @ObservedObject var calendar: CalendarService
    let select: (SidebarItem) -> Void

    var body: some View {
        TimelineView(.everyMinute) { context in
            let when = Self.when(key: key, members: state.seriesMembers(key), events: calendar.upcomingEvents, now: context.date)
            Button { select(.series(key)) } label: {
                HStack(spacing: 8) {
                    Text(name)
                        .font(.paperChat)
                        .foregroundStyle(Paper.ink)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if let when {
                        Text(when.text)
                            // Ink, not red: the next meeting's own row above is the loud one.
                            .font(.system(size: 13, weight: when.soon ? .semibold : .regular).monospacedDigit())
                            .foregroundStyle(when.soon ? Paper.ink : Paper.inkMuted)
                    }
                }
                .modifier(SidebarRowBackground(selected: state.selection == .series(key), height: 32))
            }
            .buttonStyle(.plain)
            .help(when?.soon == true ? "\(name) is next: open the brief" : "\(name): \(count) meetings")
            .id(SidebarItem.series(key))
        }
    }

    /// "11:42" (in ink) when it meets again today, else "Today", "Tue", "Sep 29".
    static func when(key: String, members: [Meeting], events: [CalendarCandidate], now: Date,
                     calendar: Calendar = .current) -> (text: String, soon: Bool)? {
        if let next = events.filter({ $0.end > now && calendar.isDate($0.start, inSameDayAs: now)
                                      && MeetingSeries.key(title: $0.title) == key })
            .min(by: { $0.start < $1.start }),
           !members.contains(where: { $0.info.calendarEventID == next.id }) {
            return (next.start.formatted(date: .omitted, time: .shortened), true)
        }
        guard let last = members.first?.info.startedAt else { return nil }
        let day = SidebarDay.label(for: last, now: now, calendar: calendar)
        if day == "Today" || day == "Yesterday" { return (day, false) }
        if let week = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)), last >= week {
            return (last.formatted(.dateTime.weekday(.abbreviated)), false)
        }
        return (last.formatted(.dateTime.month(.abbreviated).day()), false)
    }
}

/// A sidebar heading in the page's serif, with a hairline running out to the
/// edge: "Series ─────". Reads as a section, never as a row.
struct SidebarSectionTitle: View {
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.paperTitle(size: 15))
                .foregroundStyle(Paper.ink)
                .accessibilityAddTraits(.isHeader)
            Rectangle().fill(Paper.hairline).frame(height: 1)
        }
        .padding(.horizontal, 10)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }
}
