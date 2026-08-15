import Foundation
import MCP

/// Typed access to a `tools/call` argument bag.
///
/// As in the contacts server, an absent key and an explicit `null` mean different
/// things: omitting `location` leaves it alone, passing `location: null` clears it.
public struct Arguments {
    private let values: [String: Value]
    private let calendar: Calendar

    public init(_ values: [String: Value]?, calendar: Calendar) {
        self.values = values ?? [:]
        self.calendar = calendar
    }

    // MARK: Scalars

    public func requiredString(_ name: String) throws -> String {
        guard let raw = values[name]?.stringValue else { throw ToolError.missingArgument(name) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolError.badArgument(name: name, reason: "it is empty")
        }
        return trimmed
    }

    public func optionalString(_ name: String) -> String? {
        guard let text = values[name]?.stringValue else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func bool(_ name: String, default fallback: Bool = false) -> Bool {
        values[name]?.boolValue ?? fallback
    }

    /// Clamps rather than rejects: a model asking for 500 results means "as many as you
    /// will give me".
    public func int(_ name: String, default fallback: Int, in range: ClosedRange<Int>) throws
        -> Int
    {
        guard let raw = values[name] else { return fallback }
        guard let number = raw.intValue else {
            throw ToolError.badArgument(name: name, reason: "an integer was expected")
        }
        return Swift.min(Swift.max(number, range.lowerBound), range.upperBound)
    }

    public func stringArray(_ name: String) throws -> [String] {
        guard let raw = values[name] else { return [] }
        if case .null = raw { return [] }
        // A single string where an array is expected is a common and harmless slip.
        if let single = raw.stringValue { return [single] }
        guard let entries = raw.arrayValue else {
            throw ToolError.badArgument(name: name, reason: "an array of strings was expected")
        }
        return entries.compactMap(\.stringValue)
    }

    // MARK: Dates

    public func requiredDate(_ name: String) throws -> ParsedDate {
        let raw = try requiredString(name)
        return try DateParsing.parse(raw, argument: name, calendar: calendar)
    }

    // MARK: Span

    public func span() throws -> EventSpan {
        guard let raw = optionalString("span") else { return .this }
        guard let span = EventSpan(rawValue: raw.lowercased()) else {
            throw ToolError.badArgument(
                name: "span",
                reason: "expected \"this\" or \"future\", got \"\(raw)\"")
        }
        return span
    }

    // MARK: Alarms

    /// `-15m`, `-1h`, `-1d`, `0`. Returns minutes, negative meaning before the start.
    ///
    /// A bare number is read as minutes so `-15` behaves like `-15m` rather than being
    /// rejected on a technicality.
    public static func alarmMinutes(_ raw: String) throws -> Int {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else {
            throw ToolError.badArgument(name: "alarms", reason: "an alarm entry is empty")
        }

        let multiplier: Int
        var digits = text
        switch text.last {
        case "m": multiplier = 1; digits = String(text.dropLast())
        case "h": multiplier = 60; digits = String(text.dropLast())
        case "d": multiplier = 1440; digits = String(text.dropLast())
        default: multiplier = 1
        }

        guard let magnitude = Int(digits) else {
            throw ToolError.badArgument(
                name: "alarms",
                reason: "\"\(raw)\" is not an offset; use \"-15m\", \"-1h\", \"-1d\" or \"0\"")
        }
        return magnitude * multiplier
    }

    public func alarms(_ name: String) throws -> [Int]? {
        guard let raw = values[name] else { return nil }
        if case .null = raw { return [] }
        guard let entries = raw.arrayValue else {
            throw ToolError.badArgument(name: name, reason: "an array of offsets was expected")
        }
        return try entries.map { entry in
            guard let text = entry.stringValue else {
                if let number = entry.intValue { return number }
                throw ToolError.badArgument(
                    name: name, reason: "each alarm must be a string like \"-15m\"")
            }
            return try Self.alarmMinutes(text)
        }
    }

    // MARK: Edits

    public func stringEdit(_ name: String) -> FieldEdit<String> {
        guard let raw = values[name] else { return .unchanged }
        if case .null = raw { return .cleared }
        guard let text = raw.stringValue else { return .unchanged }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .cleared : .set(trimmed)
    }

    public func dateEdit(_ name: String) throws -> FieldEdit<Date> {
        guard let raw = values[name] else { return .unchanged }
        if case .null = raw {
            // Start and end are not optional on an event, so there is nothing sensible
            // to clear them to.
            throw ToolError.badArgument(
                name: name, reason: "an event cannot have no \(name); pass a date instead of null")
        }
        guard let text = raw.stringValue else { return .unchanged }
        return .set(try DateParsing.parse(text, argument: name, calendar: calendar).date)
    }

    public func alarmEdit(_ name: String) throws -> FieldEdit<[Int]> {
        guard let parsed = try alarms(name) else { return .unchanged }
        return parsed.isEmpty ? .cleared : .set(parsed)
    }
}
