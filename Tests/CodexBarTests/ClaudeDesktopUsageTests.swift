import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct ClaudeDesktopUsageTests {
    private let now = Date(timeIntervalSince1970: 1000)
    private let identity = ClaudeDesktopProfileIdentity.Identity(accountID: "account-a", email: "a@example.com")

    @Test
    func `Desktop cache accepts its actual HTTPS host and prefers full scope production tokens`() {
        let client = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        let org = UUID().uuidString.lowercased()
        let base = "\(client):\(org):https://api.anthropic.com:"
        let entries: [String: Any] = [
            base + "user:profile": ["token": "partial", "expiresAt": 9_999_999.0],
            base + "user:profile user:inference": ["token": "full", "expiresAt": 1_100_000.0],
            "\(client):\(UUID()):https://api.anthropic.com:user:profile": [
                "token": "another-organization", "expiresAt": 99_999_999.0,
            ],
        ]
        #expect(ClaudeDesktopProfileIdentity.selectToken(entries: entries, organization: org, now: self.now) == "full")
        #expect(ClaudeDesktopProfileIdentity.selectToken(entries: entries, organization: UUID().uuidString) == nil)
    }

    @Test
    func `expired rejected and partial scope cache entries cannot supply usage`() {
        let client = UUID()
        let org = UUID().uuidString
        let base = "\(client):\(org):https://api.anthropic.com:"
        for expiry in [0.0, 999_999.0, 1_029_999.0] {
            let entry: [String: Any] = [base + "user:profile": ["token": "expired", "expiresAt": expiry]]
            #expect(ClaudeDesktopProfileIdentity.selectToken(entries: entry, organization: org, now: self.now) == nil)
        }
        let wrongScope: [String: Any] = [
            base + "other:user:profile": ["token": "wrong", "expiresAt": 9_999_999.0],
        ]
        #expect(ClaudeDesktopProfileIdentity.selectToken(entries: wrongScope, organization: org, now: self.now) == nil)
    }

    @Test
    func `bar uses the session limit and honors remaining or used display`() throws {
        let data = Data("""
        {"five_hour":{"utilization":10}, "limits":[{"kind":"session","percent":37}]}
        """.utf8)
        let response = try ClaudeOAuthUsageFetcher.decodeUsageResponse(data)
        let usage = try ClaudeDesktopProfileIdentity.usage(response: response, identity: self.identity, now: self.now)
        let state = ClaudeDesktopUsage()
        let context = self.context()
        #expect(state.accept(usage, requested: context, live: context))
        #expect(state.percentText(showUsed: false, now: self.now) == "63%")
        #expect(state.percentText(showUsed: true, now: self.now) == "37%")
        #expect(state.percentText(showUsed: false, now: self.now.addingTimeInterval(120)) == nil)
        #expect(StatusItemController.desktopUsageTitle(codex: "86%", claude: "63%") == "Cdx 86%  Cl 63%")
        #expect(StatusItemController.desktopUsageTitle(codex: "86%", claude: nil) == "Cdx 86%  Cl —")
        #expect(StatusItemController.customUsageIcon.isTemplate)
    }

    @Test
    func `a reset limit disappears until new usage arrives`() throws {
        let response = try ClaudeOAuthUsageFetcher.decodeUsageResponse(Data("""
        {"five_hour":{"utilization":10,"resets_at":"1970-01-01T00:17:00Z"}}
        """.utf8))
        let usage = try ClaudeDesktopProfileIdentity.usage(response: response, identity: self.identity, now: self.now)
        let state = ClaudeDesktopUsage()
        #expect(state.accept(usage, requested: self.context(), live: self.context()))
        #expect(state.percentText(showUsed: false, now: self.now) == "90%")
        #expect(state.percentText(showUsed: false, now: self.now.addingTimeInterval(20)) == nil)
    }

    @Test
    func `account process organization changes and closed Desktop reject in flight usage`() {
        let usage = ClaudeDesktopProfileIdentity.Usage(
            identity: self.identity, usedPercent: 37, resetsAt: nil, fetchedAt: self.now)
        let requested = self.context()
        let changed = [
            self.context(accountID: "account-b"), self.context(processID: 2),
            self.context(organization: "organization-b"), nil,
        ]
        for live in changed {
            let state = ClaudeDesktopUsage()
            #expect(state.accept(usage, requested: requested, live: requested))
            #expect(!state.accept(usage, requested: requested, live: live))
            #expect(state.percentText(showUsed: false, now: self.now) == nil)
        }
    }

    @Test
    func `missing invalid or foreign account usage never becomes a percentage`() throws {
        for json in ["{}", "{\"five_hour\":{\"utilization\":-1}}", "{\"five_hour\":{\"utilization\":101}}"] {
            let response = try ClaudeOAuthUsageFetcher.decodeUsageResponse(Data(json.utf8))
            #expect(throws: ClaudeDesktopProfileIdentity.Failure.self) {
                try ClaudeDesktopProfileIdentity.usage(response: response, identity: self.identity)
            }
        }
        let state = ClaudeDesktopUsage()
        let other = ClaudeDesktopProfileIdentity.Identity(accountID: "account-b", email: "b@example.com")
        let usage = ClaudeDesktopProfileIdentity.Usage(
            identity: other, usedPercent: 37, resetsAt: nil, fetchedAt: self.now)
        #expect(!state.accept(usage, requested: self.context(), live: self.context()))
        #expect(state.percentText(showUsed: false, now: self.now) == nil)
    }

    private func context(
        accountID: String = "account-a",
        processID: pid_t = 1,
        organization: String = "organization-a") -> ClaudeDesktopUsage.Context
    {
        ClaudeDesktopUsage.Context(
            directory: URL(fileURLWithPath: "/synthetic/profile"),
            accountID: accountID,
            processID: processID,
            organizationFingerprint: organization)
    }
}
