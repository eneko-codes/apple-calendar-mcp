import CalendarMCPCore
import Foundation

// Launcher only. Everything testable lives in CalendarMCPCore, which the test target
// imports; an executable target cannot be imported.
await CalendarMCPServer.run()
