import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct ClaudeDesktopUsageTests {
    private let now = Date(timeIntervalSince1970: 1000)
    private let identity = ClaudeDesktopProfileIdentity.Identity(accountID: "account-a", email: "a@example.com")

    @Test
    func `minimal desktop menu keeps refresh and removes links and footer actions`() {
        let sections: [MenuDescriptor.Section] = [.init(entries: [
            .text("Status", .secondary), .submenu("Plan Usage", nil, []),
            .action("Terminal", .openTerminal(command: "claude")), .action("Dashboard", .dashboard),
            .action("Refresh", .refresh), .action("Settings", .settings),
            .action("About", .about), .action("Quit", .quit),
        ])]
        let minimal = StatusItemController.desktopMenuSections(sections, minimal: true)
        #expect(minimal.count == 1)
        #expect(minimal.first?.entries.count == 1)
        if case .action(_, .refresh) = minimal[0].entries[0] {} else {
            Issue.record("Only refresh should remain")
        }
        #expect(StatusItemController.desktopMenuSections(sections, minimal: false).first?.entries.count == 8)
    }

    @Test
    func `desktop visual limits preserve scoped weekly models resets and paid usage units`() throws {
        let data = Data("""
        {"limits":[{"kind":"session","percent":0},
          {"kind":"weekly_scoped","group":"weekly","percent":24,
           "resets_at":"2030-10-11T12:00:00Z","scope":{"model":{"id":"fable","display_name":"Fable"}}}],
         "seven_day":{"utilization":80},
         "extra_usage":{"is_enabled":true,"used_credits":125,"monthly_limit":1000,"currency":"USD"}}
        """.utf8)
        let response = try ClaudeOAuthUsageFetcher.decodeUsageResponse(data)
        let usage = try ClaudeDesktopProfileIdentity.usage(response: response, identity: self.identity, now: self.now)
        #expect(usage.weeklyLimits.count == 1)
        #expect(usage.weeklyLimits.first?.title == "Fable")
        #expect(usage.weeklyLimits.first?.usedPercent == 24)
        #expect(usage.weeklyLimits.first?.resetsAt != nil)
        #expect(usage.extraUsage?.used == 1.25)
        #expect(usage.extraUsage?.limit == 10)
        let uncapped = try ClaudeOAuthUsageFetcher.decodeUsageResponse(Data(
            "{\"extra_usage\":{\"is_enabled\":true,\"used_credits\":125,\"monthly_limit\":0}}".utf8))
        #expect(try ClaudeDesktopProfileIdentity.extraUsage(uncapped.extraUsage) == nil)
        let legacy = try ClaudeOAuthUsageFetcher.decodeUsageResponse(Data("""
        {"five_hour":{"utilization":1},"seven_day":{"utilization":12},"seven_day_opus":{"utilization":34}}
        """.utf8))
        #expect(try ClaudeDesktopProfileIdentity.weeklyLimits(response: legacy).map(\.title) == ["Semana", "Opus"])
        let invalid = try ClaudeOAuthUsageFetcher.decodeUsageResponse(Data(
            "{\"limits\":[{\"group\":\"weekly\",\"percent\":101}]}".utf8))
        #expect(throws: ClaudeDesktopProfileIdentity.Failure.self) {
            try ClaudeDesktopProfileIdentity.weeklyLimits(response: invalid)
        }
    }

    @Test
    func `desktop card uses only desktop usage and reports its own failures`() {
        let ready = ClaudeDesktopUsageCard.State(
            email: "a@example.com", percentage: "99%", showUsed: false, error: nil, isOpen: true)
        #expect(ready.sessionText == "Current Session: 99% Remaining")
        #expect(ready.statusText == nil)
        let denied = ClaudeDesktopUsageCard.State(
            email: nil, percentage: nil, showUsed: false, error: "Desktop permission required", isOpen: true)
        #expect(denied.sessionText == nil)
        #expect(denied.statusText == "Desktop permission required")
        let closed = ClaudeDesktopUsageCard.State(
            email: nil, percentage: nil, showUsed: false, error: nil, isOpen: false)
        #expect(closed.statusText == "Open Claude to show the active account's usage.")
    }

    @Test
    func `background verification never reads a secret when the installed executable needs authorization`() throws {
        for outcome in [
            KeychainAccessPreflight.Outcome.interactionRequired,
            .temporarilyUnavailable,
            .notFound,
            .failure(-1),
        ] {
            var readCalled = false
            #expect(throws: ClaudeDesktopProfileIdentity.Failure.self) {
                try ClaudeDesktopProfileIdentity.readSafeStorage(
                    allowInteraction: false,
                    preflight: { outcome },
                    read: { readCalled = true; return Data() })
            }
            #expect(!readCalled)
        }
        let authorized = try ClaudeDesktopProfileIdentity.readSafeStorage(
            allowInteraction: false, preflight: { .allowed }, read: { Data("fixture".utf8) })
        #expect(authorized == Data("fixture".utf8))
    }

    @Test
    func `explicit verification can request authorization instead of getting stuck behind background reads`() throws {
        var preflightCalled = false
        let data = try ClaudeDesktopProfileIdentity.readSafeStorage(
            allowInteraction: true,
            preflight: { preflightCalled = true; return .interactionRequired },
            read: { Data("fixture".utf8) })
        #expect(data == Data("fixture".utf8))
        #expect(!preflightCalled)
    }

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
        #expect(StatusItemController.desktopUsageTitle(codex: "86%", claude: "63%") == "Cdx 86  Cl 63")
        #expect(StatusItemController.desktopUsageTitle(codex: "86%", claude: nil) == "Cdx 86  Cl —")
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

    @Test
    func `forced refresh bypasses the background interval without requesting keychain UI`() async {
        let context = self.context()
        let usage = ClaudeDesktopProfileIdentity.Usage(
            identity: self.identity, usedPercent: 37, resetsAt: nil, fetchedAt: self.now)
        var requests: [Bool] = []
        var accepted = 0
        let state = ClaudeDesktopUsage(
            contextResolver: { context },
            usageReader: { _, interaction in
                requests.append(interaction)
                return usage
            },
            identityAcceptor: { _, _ in accepted += 1 })
        state.refresh()
        for _ in 0..<1000 where accepted < 1 {
            await Task.yield()
        }
        #expect(accepted == 1)
        state.refresh()
        await Task.yield()
        #expect(requests == [false])
        state.refresh(force: true)
        for _ in 0..<1000 where accepted < 2 {
            await Task.yield()
        }
        #expect(accepted == 2)
        #expect(requests == [false, false])
    }

    @Test
    func `explicit verification supersedes background work and ignores its late result`() async {
        let context = self.context()
        let backgroundUsage = ClaudeDesktopProfileIdentity.Usage(
            identity: self.identity, usedPercent: 10, resetsAt: nil, fetchedAt: self.now)
        let verifiedUsage = ClaudeDesktopProfileIdentity.Usage(
            identity: self.identity, usedPercent: 37, resetsAt: nil, fetchedAt: self.now)
        var pending: CheckedContinuation<ClaudeDesktopProfileIdentity.Usage, Never>?
        var accepted = 0
        let state = ClaudeDesktopUsage(
            contextResolver: { context },
            usageReader: { _, interaction in
                if interaction { return verifiedUsage }
                return await withCheckedContinuation { pending = $0 }
            },
            identityAcceptor: { _, _ in accepted += 1 })
        state.refresh()
        for _ in 0..<1000 where pending == nil {
            await Task.yield()
        }
        #expect(pending != nil)
        state.refresh(allowInteraction: true)
        for _ in 0..<1000 where accepted < 1 {
            await Task.yield()
        }
        #expect(accepted == 1)
        #expect(state.usage?.usedPercent == 37)
        pending?.resume(returning: backgroundUsage)
        await Task.yield()
        #expect(accepted == 1)
        #expect(state.usage?.usedPercent == 37)
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
