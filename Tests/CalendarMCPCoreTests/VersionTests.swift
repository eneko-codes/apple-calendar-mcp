import Foundation
import Testing

@testable import CalendarMCPCore

@Suite("Version agreement")
struct VersionTests {

    /// Derived from this file's own path: SwiftPM makes no promise about the working
    /// directory a test runs in.
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // CalendarMCPCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // package root

    /// The server is built from the system's own frameworks and nothing else. A dependency
    /// is a decision for the owner, so adding one has to break this test first.
    @Test("The package declares no third-party dependency")
    func noDependencies() throws {
        let package = try String(
            contentsOf: Self.repositoryRoot.appending(path: "Package.swift"), encoding: .utf8)
        #expect(!package.contains(".package("), "Package.swift declares a dependency")
        #expect(!package.contains(".product("))
    }
}
