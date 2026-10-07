import AppKit
import CodexBarCore
import SwiftUI

extension StatusItemController {
    func addClaudeDesktopUsageCard(to menu: NSMenu, context: MenuCardContext) -> Bool {
        // Provider-specific by design: this installation displays the active Claude Desktop account instead of CLI
        // credentials.
        guard context.currentProvider == .claude,
              self.settings.userDefaults.bool(forKey: "customDesktopMenuBarEnabled") else { return false }
        let usage = ClaudeDesktopUsage.shared
        let profiles = ClaudeDesktopProfiles.shared
        let running: [ClaudeDesktopProfiles.RunningProfile]
        var detectionError: String?
        do {
            running = try profiles.running()
        } catch {
            running = []
            detectionError = error.localizedDescription
            self.menuLogger.error("Claude Desktop card detection failed: \(error.localizedDescription)")
        }
        let email = running.count == 1 ? profiles.email(for: running.first?.profileID) : nil
        let state = ClaudeDesktopUsageCard.State(
            email: PersonalInfoRedactor.redactEmails(in: email, isEnabled: self.settings.hidePersonalInfo),
            percentage: usage.percentText(showUsed: self.settings.usageBarsShowUsed),
            showUsed: self.settings.usageBarsShowUsed,
            error: detectionError ?? usage.error,
            isOpen: !running.isEmpty,
            usage: usage.percentText(showUsed: true) == nil ? nil : usage.usage)
        menu.addItem(self.makeMenuCardItem(
            ClaudeDesktopUsageCard(state: state, width: context.menuWidth),
            id: "claudeDesktopUsage",
            width: context.menuWidth))
        menu.addItem(.separator())
        return true
    }
}

struct ClaudeDesktopUsageCard: View {
    struct State: Equatable {
        let email: String?
        let percentage: String?
        let showUsed: Bool
        let error: String?
        let isOpen: Bool
        var usage: ClaudeDesktopProfileIdentity.Usage?

        var sessionText: String? {
            self.percentage.map { "Current Session: \($0) \(self.showUsed ? "Used" : "Remaining")" }
        }

        var statusText: String? {
            if let error { return error }
            if !self.isOpen { return "Open Claude to show the active account's usage." }
            if self.percentage == nil { return "Reading the active account's usage…" }
            return nil
        }
    }

    let state: State
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Claude").font(.headline)
            if let email = self.state.email {
                Text(email).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let usage = self.state.usage {
                ClaudeDesktopLimitRow(
                    title: "Sesión", usedPercent: usage.usedPercent, resetsAt: usage.resetsAt,
                    showUsed: self.state.showUsed)
                if !usage.weeklyLimits.isEmpty {
                    Divider()
                    ForEach(usage.weeklyLimits) { limit in
                        ClaudeDesktopLimitRow(
                            title: limit.title, usedPercent: limit.usedPercent, resetsAt: limit.resetsAt,
                            showUsed: self.state.showUsed)
                    }
                }
                if let extra = usage.extraUsage {
                    Divider()
                    ClaudeDesktopLimitRow(
                        title: "Uso Extra", usedPercent: min(100, extra.used / extra.limit * 100),
                        resetsAt: nil, showUsed: self.state.showUsed)
                    Text("\(UsageFormatter.currencyString(extra.used, currencyCode: extra.currency)) / "
                        + "\(UsageFormatter.currencyString(extra.limit, currencyCode: extra.currency))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let status = self.state.statusText {
                Text(status)
                    .foregroundStyle(self.state.error == nil ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: self.width, alignment: .leading)
    }
}
