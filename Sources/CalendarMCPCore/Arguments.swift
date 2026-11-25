import Foundation

/// Typed access to a `tools/call` argument bag.
///
/// A class, not a struct, so that reading a number can also record that it was moved into
/// its range without every reader having to be `mutating`. One instance serves one call and
/// never leaves it. The tool puts `notices` before the data.
///
/// For a field an update may empty, an absent key and an explicit `null` mean different
/// things: omitting `location` leaves it alone, passing `location: null` clears it.
/// Everywhere else `null` is the same as not given.
public final class Arguments {
    private let values: [String: Value]
    private let calendar: Calendar

    /// One sentence for each number that was moved into its range, in the order read.
    public private(set) var notices: [String] = []

    public init(_ values: [String: Value]?, calendar: Calendar) {
        self.values = values ?? [:]
        self.calendar = calendar
    }

    /// `nil` when the argument is absent or null.
    private func given(_ name: String) -> Value? {
        guard let raw = values[name], !raw.isNull else { return nil }
        return raw
    }

    private func text(_ raw: Value, _ name: String) throws -> String {
        guard let text = raw.stringValue else {
            throw ToolError.badArgument(name: name, reason: "text was expected")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Scalars

    public func requiredString(_ name: String) throws -> String {
        guard let raw = given(name) else { throw ToolError.missingArgument(name) }
        let trimmed = try text(raw, name)
        guard !trimmed.isEmpty else {
            throw ToolError.badArgument(name: name, reason: "it is empty")
        }
        return trimmed
    }

    public func optionalString(_ name: String) throws -> String? {
        guard let raw = given(name) else { return nil }
        let trimmed = try text(raw, name)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func bool(_ name: String, default fallback: Bool = false) throws -> Bool {
        guard let raw = given(name) else { return fallback }
        guard let flag = raw.boolValue else {
            throw ToolError.badArgument(name: name, reason: "true or false was expected")
        }
        return flag
    }

    /// A quantity: a size or a count. Outside its range it is moved to the nearest allowed
    /// value, and `notices` gains the sentence that says which value was used.
    public func int(_ name: String, default fallback: Int, in range: ClosedRange<Int>) throws
        -> Int
    {
        guard let raw = given(name) else { return fallback }
        guard let number = raw.intValue else {
            throw ToolError.badArgument(name: name, reason: "a whole number was expected")
        }
        return ToolStandard.clamp(number, to: range, argument: name, notices: &notices)
    }

    /// The `limit` and `offset` of a listing, read the same way by every tool that pages.
    public func page(defaultLimit: Int, limits: ClosedRange<Int>) throws -> (limit: Int, offset: Int) {
        (
            try int("limit", default: defaultLimit, in: limits),
            try int("offset", default: 0, in: Configuration.offsetRange)
        )
    }

    /// The `character_offset` and `max_characters` of a window on one long text.
    public func window() throws -> (characterOffset: Int, maxCharacters: Int) {
        (
            try int("character_offset", default: 0, in: Configuration.offsetRange),
            try int(
                "max_characters", default: Configuration.defaultMaxCharacters,
                in: Configuration.maxCharactersRange)
        )
    }

    public func stringArray(_ name: String) throws -> [String] {
        guard let raw = given(name) else { return [] }
        // A single string where an array is expected is a common and harmless slip.
        let entries = raw.stringValue.map { [Value.string($0)] } ?? raw.arrayValue
        guard let entries, entries.allSatisfy({ $0.stringValue != nil }) else {
            throw ToolError.badArgument(name: name, reason: "an array of text was expected")
        }
        // An empty entry is not given, as an empty text argument is not.
        return entries.compactMap(\.stringValue)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    // MARK: Dates

    public func optionalDate(_ name: String) throws -> ParsedDate? {
        guard let raw = try optionalString(name) else { return nil }
        return try DateParsing.parse(raw, argument: name, calendar: calendar)
    }

    public func requiredDate(_ name: String) throws -> ParsedDate {
        let raw = try requiredString(name)
        return try DateParsing.parse(raw, argument: name, calendar: calendar)
    }

    // MARK: Span

    public func span() throws -> EventSpan {
        guard let raw = try optionalString("span") else { return .this }
        guard let span = EventSpan(rawValue: raw.lowercased()) else {
            throw ToolError.badArgument(
                name: "span",
                reason: "expected \"this\" or \"future\", got \"\(ToolStandard.echo(raw))\"")
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
                reason:
                    "\"\(ToolStandard.echo(raw))\" is not an offset; use \"-15m\", \"-1h\", \"-1d\" or \"0\"")
        }
        // Multiplied with a check, because a number of days near the top of Int would
        // otherwise trap and take the server down with it.
        let (minutes, overflow) = magnitude.multipliedReportingOverflow(by: multiplier)
        guard !overflow else { throw ToolError.alarmTooFar }
        return try alarmWithinReach(minutes)
    }

    /// An alarm outside the range is refused, not moved: the nearest allowed offset would
    /// be a different alarm from the one asked for.
    private static func alarmWithinReach(_ minutes: Int) throws -> Int {
        guard Configuration.alarmMinutesRange.contains(minutes) else { throw ToolError.alarmTooFar }
        return minutes
    }

    /// `nil` when not given; empty when given as `null` or `[]`.
    public func alarms(_ name: String) throws -> [Int]? {
        guard let raw = values[name] else { return nil }
        if raw.isNull { return [] }
        guard let entries = raw.arrayValue else {
            throw ToolError.badArgument(name: name, reason: "an array of offsets was expected")
        }
        return try entries.map { entry in
            guard let text = entry.stringValue else {
                if let number = entry.intValue { return try Self.alarmWithinReach(number) }
                throw ToolError.badArgument(
                    name: name, reason: "each alarm must be text like \"-15m\"")
            }
            return try Self.alarmMinutes(text)
        }
    }

    // MARK: Edits

    public func stringEdit(_ name: String) throws -> FieldEdit<String> {
        guard let raw = values[name] else { return .unchanged }
        if raw.isNull { return .cleared }
        let trimmed = try text(raw, name)
        return trimmed.isEmpty ? .cleared : .set(trimmed)
    }

    public func dateEdit(_ name: String) throws -> FieldEdit<Date> {
        guard let raw = values[name] else { return .unchanged }
        if raw.isNull {
            // Start and end are not optional on an event, so there is nothing sensible
            // to clear them to.
            throw ToolError.badArgument(
                name: name, reason: "an event cannot have no \(name); pass a date instead of null")
        }
        return .set(try DateParsing.parse(try text(raw, name), argument: name, calendar: calendar).date)
    }

    public func alarmEdit(_ name: String) throws -> FieldEdit<[Int]> {
        guard let parsed = try alarms(name) else { return .unchanged }
        return parsed.isEmpty ? .cleared : .set(parsed)
    }
}
