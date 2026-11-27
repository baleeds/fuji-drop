import Foundation

public enum TimeSampling {
    /// Picks up to `count` items spread evenly across the items' time span (first and last
    /// included), so a day that's mostly one burst still shows its morning and evening.
    ///
    /// `items` must already be in time order. Falls back to even spacing by position when any
    /// item lacks a date. The result keeps the input order.
    public static func spread<T>(_ items: [T], count: Int, date: (T) -> Date?) -> [T] {
        guard count > 0, !items.isEmpty else { return [] }
        guard items.count > count else { return items }
        guard count > 1 else { return [items[0]] }

        let dates = items.map(date)
        let times: [Double]
        if dates.allSatisfy({ $0 != nil }) {
            times = dates.map { $0!.timeIntervalSinceReferenceDate }
        } else {
            times = items.indices.map(Double.init)
        }
        let start = times.first!, end = times.last!

        var chosen = Set<Int>()
        for i in 0..<count {
            let target = start + (end - start) * Double(i) / Double(count - 1)
            // Nearest unchosen item to the target time; ties go to the earlier item.
            let best = times.indices
                .filter { !chosen.contains($0) }
                .min { (abs(times[$0] - target), $0) < (abs(times[$1] - target), $1) }
            if let best { chosen.insert(best) }
        }
        return chosen.sorted().map { items[$0] }
    }
}
