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

    private func manifest() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.repositoryRoot.appending(path: "extension/manifest.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The installer keys on the manifest version alone, so a build whose three version
    /// strings disagree describes a build nobody has.
    @Test("The manifest, the server constant and Info.plist carry the same version")
    func versionsAgree() throws {
        let plistData = try Data(contentsOf: Self.repositoryRoot.appending(path: "Resources/Info.plist"))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        #expect(try manifest()["version"] as? String == CalendarMCPServer.version)
        #expect(plist["CFBundleShortVersionString"] as? String == CalendarMCPServer.version)
    }

    /// A tool missing from the manifest has no permission switch at all, and the manifest
    /// is read before the server has ever run.
    @Test("The manifest lists exactly the tools the server offers")
    func manifestListsEveryTool() throws {
        let listed = try #require(try manifest()["tools"] as? [[String: Any]])
        let names = listed.compactMap { $0["name"] as? String }
        #expect(names == ToolCatalog.all().map(\.name))
        for tool in listed {
            #expect((tool["description"] as? String)?.isEmpty == false)
        }
    }

    /// The manifest is plain JSON and cannot take a figure from a constant, so this holds
    /// the bounds it states to the ones the code enforces.
    @Test("The manifest states the sizes the server enforces")
    func manifestStatesTheSizes() throws {
        let description = try #require(try manifest()["long_description"] as? String)
        #expect(description.contains("no more than \(Configuration.longestScanDays) days"))
        #expect(description.contains("after \(Configuration.callTimeout.components.seconds) seconds"))
    }

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
