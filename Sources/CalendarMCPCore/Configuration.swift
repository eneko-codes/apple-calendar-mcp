import Foundation

/// What used to be settings the person installing the extension could change, before the
/// owner's plug-and-play rule removed "Calendars Claude may use", "Longest search range
/// (days)" and "Default search results" from the connector's settings entirely: only the
/// per-tool allow/ask/prohibit switch in Claude Desktop controls this server now.
public enum Configuration {
    /// Ceiling on a single search range. EventKit degrades badly over long spans.
    public static let maximumRangeDays = 366

    /// Default page size for `calendar_search`. A tool's own `limit` still wins.
    public static let searchLimit = 50

    public static let searchLimitRange = 1...200

    /// Paging ceiling. Declared here so the advertised schema and the enforced clamp
    /// cannot drift: both read this one value.
    public static let offsetRange = 0...10_000
}
