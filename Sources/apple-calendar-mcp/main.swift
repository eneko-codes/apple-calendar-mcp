import CalendarMCPCore
import Foundation

// Launcher only. Everything testable lives in CalendarMCPCore, which the test target
// imports; an executable target cannot be imported.
do {
    try await CalendarMCPServer.run()
} catch {
    // stdout carries JSON-RPC and nothing else, so the one diagnostic this process ever
    // prints goes to stderr. Exiting 0 here would be indistinguishable from a clean
    // shutdown, which is how a server disappears mid-session with nothing to show for it.
    FileHandle.standardError.write(
        Data("apple-calendar-mcp: \(error.localizedDescription)\n".utf8))
    exit(1)
}
