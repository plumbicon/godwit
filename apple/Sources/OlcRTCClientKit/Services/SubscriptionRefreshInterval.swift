import Foundation

enum SubscriptionRefreshInterval {
    static func seconds(from rawValue: String?) -> TimeInterval? {
        guard let interval = parsedInterval(from: rawValue) else {
            return nil
        }

        let seconds = interval.number * interval.unit.multiplier
        return seconds.isFinite ? seconds : nil
    }

    static func localizedString(from rawValue: String?, languageCode: String = AppLocalization.timeLanguageCode) -> String? {
        guard let interval = parsedInterval(from: rawValue) else {
            return nil
        }

        return "\(interval.numberText)\(interval.unit.localizedSuffix(languageCode: languageCode))"
    }

    static func abbreviatedString(
        from seconds: TimeInterval,
        languageCode: String = AppLocalization.timeLanguageCode
    ) -> String {
        let seconds = max(0, Int(seconds.rounded(.down)))
        let units: [(value: Int, unit: RefreshUnit)] = [
            (86_400, .days),
            (3_600, .hours),
            (60, .minutes),
            (1, .seconds),
        ]

        for unit in units where seconds >= unit.value {
            let count = seconds / unit.value
            return "\(count)\(unit.unit.localizedSuffix(languageCode: languageCode))"
        }

        return "0\(RefreshUnit.seconds.localizedSuffix(languageCode: languageCode))"
    }

    static func nanoseconds(from seconds: TimeInterval) -> UInt64? {
        let nanoseconds = seconds * 1_000_000_000
        guard nanoseconds.isFinite,
              nanoseconds > 0,
              nanoseconds <= TimeInterval(UInt64.max) else {
            return nil
        }
        return UInt64(nanoseconds.rounded(.up))
    }

    private static func parsedInterval(from rawValue: String?) -> ParsedInterval? {
        guard let rawValue else {
            return nil
        }

        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawUnit = value.last,
              let unit = RefreshUnit(rawValue: String(rawUnit).lowercased()) else {
            return nil
        }

        let numberText = value
            .dropLast()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = Double(numberText), number.isFinite, number > 0 else {
            return nil
        }

        return ParsedInterval(numberText: numberText, number: number, unit: unit)
    }
}

private struct ParsedInterval {
    var numberText: String
    var number: Double
    var unit: RefreshUnit
}

private enum RefreshUnit: String {
    case seconds = "s"
    case minutes = "m"
    case hours = "h"
    case days = "d"

    var multiplier: TimeInterval {
        switch self {
        case .seconds:
            1
        case .minutes:
            60
        case .hours:
            60 * 60
        case .days:
            24 * 60 * 60
        }
    }

    func localizedSuffix(languageCode: String) -> String {
        let isRussian = languageCode == "ru"
        switch self {
        case .seconds:
            return isRussian ? "с" : "s"
        case .minutes:
            return isRussian ? "м" : "m"
        case .hours:
            return isRussian ? "ч" : "h"
        case .days:
            return isRussian ? "д" : "d"
        }
    }
}
