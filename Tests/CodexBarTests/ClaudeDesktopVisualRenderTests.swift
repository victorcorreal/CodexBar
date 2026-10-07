import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

@MainActor
final class ClaudeDesktopVisualRenderTests: XCTestCase {
    func test_renderSyntheticDesktopLimits() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_DESKTOP_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_DESKTOP_SCREENSHOT_DIR to render the synthetic Desktop card.")
        }
        let data = Data("""
        {"five_hour":{"utilization":18},
         "limits":[{"kind":"weekly_scoped","group":"weekly","percent":24,
          "resets_at":"2030-10-11T12:00:00Z","scope":{"model":{"id":"fable","display_name":"Fable"}}}],
         "extra_usage":{"is_enabled":true,"used_credits":125,"monthly_limit":1000,"currency":"USD"}}
        """.utf8)
        let response = try ClaudeOAuthUsageFetcher.decodeUsageResponse(data)
        let identity = ClaudeDesktopProfileIdentity.Identity(accountID: "fixture", email: "cuenta@example.com")
        let usage = try ClaudeDesktopProfileIdentity.usage(response: response, identity: identity)
        let state = ClaudeDesktopUsageCard.State(
            email: identity.email, percentage: "82%", showUsed: false, error: nil, isOpen: true, usage: usage)
        let view = ClaudeDesktopUsageCard(state: state, width: 360)
            .environment(\.colorScheme, .dark)
            .environment(\.locale, Locale(identifier: "es_ES"))
            .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: .darkAqua)
        let png = try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("claude-desktop-synthetic.png"))
        XCTAssertEqual(hosting.frame.width, 360)
    }
}
