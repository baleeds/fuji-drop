import Foundation

/// Shots from one calendar day (or the shots with no date).
public struct DayGroup<T> {
    /// Start of the day, or nil for undated shots.
    public var day: Date?
    public var items: [T]
}

public enum DayGrouping {
    /// Groups items by calendar day, newest day first; undated items go last.
    public static func group<T>(
        _ items: [T],
        date: (T) -> Date?,
        calendar: Calendar = .current
    ) -> [DayGroup<T>] {
        var byDay: [Date: [T]] = [:]
        var undated: [T] = []
        for item in items {
            if let d = date(item) {
                byDay[calendar.startOfDay(for: d), default: []].append(item)
            } else {
                undated.append(item)
            }
        }
        var groups = byDay.keys.sorted(by: >).map { DayGroup(day: $0, items: byDay[$0]!) }
        if !undated.isEmpty { groups.append(DayGroup(day: nil, items: undated)) }
        return groups
    }
}
