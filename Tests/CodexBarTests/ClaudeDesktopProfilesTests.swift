import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct ClaudeDesktopProfilesTests {
    @Test
    func `switch waits for a slow Claude shutdown beyond the old eight second window`() async throws {
        var polls = 0
        let closed = try await ClaudeDesktopProfiles.waitForQuit(
            isClosed: { polls >= 40 }, pause: { polls += 1 })
        #expect(closed)
        #expect(polls == 40)
    }

    @Test
    func `quit timeout stays bounded when Claude refuses to close`() async throws {
        var polls = 0
        let closed = try await ClaudeDesktopProfiles.waitForQuit(
            pollLimit: 3, isClosed: { false }, pause: { polls += 1 })
        #expect(!closed)
        #expect(polls == 3)
    }

    @Test
    func `already closed Claude does not delay opening the next profile`() async throws {
        var paused = false
        let closed = try await ClaudeDesktopProfiles.waitForQuit(
            isClosed: { true }, pause: { paused = true })
        #expect(closed)
        #expect(!paused)
    }

    @Test
    func `profile creation persists isolated directories without copying existing login`() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ClaudeDesktopProfiles(home: home)
        let profile = try store.create(name: " Work ")
        let reopened = ClaudeDesktopProfiles(home: home)
        #expect(reopened.profiles.count == 1)
        #expect(reopened.profiles.first?.name == "Work")
        #expect(reopened.directory(for: profile.id) != reopened.directory(for: nil))
        #expect(FileManager.default.fileExists(atPath: store.directory(for: profile.id).path))
        #expect(!FileManager.default.fileExists(atPath: store.directory(for: profile.id)
                .appendingPathComponent("config.json").path))
    }

    @Test
    func `verified email and selection survive restart but never cross account owners`() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ClaudeDesktopProfiles(home: home)
        let profile = try store.create(name: "Work")
        let directory = store.directory(for: profile.id)
        let owner = UUID().uuidString.lowercased()
        let config = directory.appendingPathComponent("config.json")
        try JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": owner]).write(to: config)
        let identity = try #require(ClaudeDesktopProfileIdentity.verifiedIdentity(
            expectedAccountID: owner, responseAccountID: owner, email: "work@example.com"))
        store.acceptIdentity(identity, directory: directory)
        try store.rememberSelection(id: profile.id)
        let reopened = ClaudeDesktopProfiles(home: home)
        #expect(reopened.email(for: profile.id) == "work@example.com")
        #expect(reopened.rememberedSelection == profile.id.uuidString)
        #expect(reopened.email(for: nil) == nil)
        try JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": UUID().uuidString]).write(to: config)
        #expect(reopened.email(for: profile.id) == nil)
        try reopened.rememberSelection(id: nil)
        #expect(ClaudeDesktopProfiles(home: home).rememberedSelection == "existing")
    }

    @Test
    func `corrupt profile storage cannot be overwritten by adding an account`() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("Library/Application Support/CodexBar/ClaudeDesktopProfiles")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("profiles.json")
        let original = Data("broken".utf8)
        try original.write(to: file)
        let store = ClaudeDesktopProfiles(home: home)
        #expect(throws: (any Error).self) { try store.create(name: "Work") }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test
    func `running account detection rejects helpers unknown directories and path prefixes`() {
        let id = UUID()
        let executable = "/Applications/Claude.app/Contents/MacOS/Claude"
        let path = "/Users/test/Library/Application Support/Profiles/work"
        let directories: [(UUID?, String)] = [(id, path)]
        #expect(ClaudeDesktopProfiles.profileID(command: executable, directories: directories) != nil)
        let match = ClaudeDesktopProfiles.profileID(
            command: executable + " --user-data-dir=" + path + " --enable-logging", directories: directories)
        #expect(match == id)
        #expect(ClaudeDesktopProfiles.profileID(
            command: executable + " --user-data-dir=" + path + "2", directories: directories) == nil)
        #expect(ClaudeDesktopProfiles.profileID(
            command: executable + " Helper --user-data-dir=" + path, directories: directories) == nil)
        #expect(ClaudeDesktopProfiles.profileID(
            command: executable + "Other", directories: directories) == nil)
    }

    @Test
    func `desktop metadata rejects malformed account identifiers`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = directory.appendingPathComponent("config.json")
        try Data("{\"lastKnownAccountUuid\":\"invalid\"}".utf8).write(to: config)
        #expect(throws: ClaudeDesktopProfileIdentity.Failure.self) {
            try ClaudeDesktopProfileIdentity.accountID(directory: directory)
        }
        let accountID = UUID()
        try JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": accountID.uuidString]).write(to: config)
        #expect(try ClaudeDesktopProfileIdentity.accountID(directory: directory) == accountID.uuidString.lowercased())
    }

    @Test
    func `desktop identity must match the active account`() {
        #expect(ClaudeDesktopProfileIdentity.verifiedIdentity(
            expectedAccountID: "account-a", responseAccountID: "account-b", email: "other@example.com") == nil)
        #expect(ClaudeDesktopProfileIdentity.verifiedIdentity(
            expectedAccountID: "account-a", responseAccountID: nil, email: "other@example.com") == nil)
        #expect(ClaudeDesktopProfileIdentity.verifiedIdentity(
            expectedAccountID: "ACCOUNT-A", responseAccountID: "account-a", email: " me@example.com ")?.email
            == "me@example.com")
    }

    @Test
    func `account scoped tombstones suppress old tokens and foreign accounts stay excluded`() {
        let cache: [String: Any] = [
            "key": ["token": "old"],
            "acct:account-a|key": NSNull(),
            "acct:account-b|foreign": ["token": "foreign"],
        ]
        let owned = ClaudeDesktopProfileIdentity.ownedEntries(cache, accountID: "account-a")
        #expect(owned["key"] is NSNull)
        #expect(owned["foreign"] == nil)
        #expect(owned.count == 1)
    }
}
