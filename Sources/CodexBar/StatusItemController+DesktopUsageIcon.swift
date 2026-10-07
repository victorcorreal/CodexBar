import AppKit
import CodexBarCore

extension StatusItemController {
    func startDesktopUsageIcon() {
        guard self.settings.userDefaults.bool(forKey: "customDesktopMenuBarEnabled"),
              !TestProcessSafety.isRunning else { return }
        ClaudeDesktopUsage.shared.didChange = { [weak self] in
            self?.updateIcons()
            self?.refreshOpenMenusAfterExplicitStoreAction()
        }
        ClaudeDesktopUsage.shared.start()
    }

    func applyDesktopUsageIcon() -> Bool? {
        guard self.settings.userDefaults.bool(forKey: "customDesktopMenuBarEnabled"),
              let button = self.statusItem.button else { return nil }
        let usage = ClaudeDesktopUsage.shared
        // Provider-specific by design: the custom bar pairs Codex with the running Claude Desktop account.
        let provider = UsageProvider.codex
        let codex = self.menuBarDisplayText(
            for: provider,
            snapshot: self.store.menuBarSnapshot(for: provider.instanceID))
        let claude = usage.percentText(showUsed: self.settings.usageBarsShowUsed)
        let text = Self.desktopUsageTitle(codex: codex, claude: claude)
        let signature = [
            "desktopUsage", text,
            String(self.shouldUseHighContrastStatusItemContent), String(self.settings.usageBarsShowUsed),
        ].joined(separator: "|")
        let skipped = self.shouldSkipMergedIconRender(signature)
        button.image = nil
        button.imagePosition = .noImage
        button.attributedTitle = NSAttributedString(string: text)
        let direction = self.settings.usageBarsShowUsed ? "used" : "remaining"
        button
            .setAccessibilityLabel(
                "Codex \(codex ?? "unavailable"), Claude Desktop \(claude ?? "unavailable") \(direction)")
        return skipped
    }

    static func desktopUsageTitle(codex: String?, claude: String?) -> String {
        let codexNumber = codex?.replacingOccurrences(of: "%", with: "") ?? "—"
        let claudeNumber = claude?.replacingOccurrences(of: "%", with: "") ?? "—"
        return "Cdx \(codexNumber)  Cl \(claudeNumber)"
    }
}
