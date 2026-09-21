import Foundation

public enum QuotaFormatting {
    public static func freshnessDescription(since date: Date, now: Date = Date()) -> String {
        let age = max(0, now.timeIntervalSince(date))
        if age < 60 { return "a few moments ago" }

        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .numeric
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    public static func countdown(until reset: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(reset.timeIntervalSince(now)))
        if seconds == 0 { return "Now" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(max(1, minutes))m"
    }

    public static func resetTimestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
