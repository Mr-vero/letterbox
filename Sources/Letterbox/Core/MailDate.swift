import Foundation

enum MailDate {
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = format
        return f
    }

    private static let internalFormat = formatter("d-MMM-yyyy HH:mm:ss Z")
    private static let rfcFormats: [DateFormatter] = [
        "EEE, d MMM yyyy HH:mm:ss Z",
        "d MMM yyyy HH:mm:ss Z",
        "EEE, d MMM yyyy HH:mm Z",
        "EEE, d MMM yyyy HH:mm:ss zzz",
        "d MMM yyyy HH:mm:ss zzz",
        "EEE, d MMM yy HH:mm:ss Z",
    ].map(formatter)
    private static let output = formatter("EEE, d MMM yyyy HH:mm:ss Z")

    static func parseInternal(_ s: String) -> Date? {
        internalFormat.date(from: s.trimmingCharacters(in: .whitespaces))
    }

    static func parseRFC2822(_ raw: String) -> Date? {
        var s = raw
        if let paren = s.firstIndex(of: "(") { s = String(s[..<paren]) }
        s = s.trimmingCharacters(in: .whitespaces)
        for f in rfcFormats {
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    static func rfc2822(_ date: Date) -> String {
        output.timeZone = .current
        return output.string(from: date)
    }
}

/// Compact, list-friendly date strings with cached formatters.
enum RelativeDate {
    private static let time: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f
    }()
    private static let weekday: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEEE"); return f
    }()
    private static let monthDay: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMM d"); return f
    }()
    private static let full: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("yMd"); return f
    }()
    private static let long: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .full; f.timeStyle = .short; f.doesRelativeDateFormatting = true; return f
    }()

    static func short(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return time.string(from: date) }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: date, to: Date()).day, days < 6 { return weekday.string(from: date) }
        if cal.isDate(date, equalTo: Date(), toGranularity: .year) { return monthDay.string(from: date) }
        return full.string(from: date)
    }

    static func detailed(_ date: Date) -> String { long.string(from: date) }
}
