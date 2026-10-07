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
        self.setButtonContent(image: Self.customUsageIcon, title: text, for: button)
        let direction = self.settings.usageBarsShowUsed ? "used" : "remaining"
        button
            .setAccessibilityLabel(
                "Codex \(codex ?? "unavailable"), Claude Desktop \(claude ?? "unavailable") \(direction)")
        return skipped
    }

    static func desktopUsageTitle(codex: String?, claude: String?) -> String {
        "Cdx \(codex ?? "—")  Cl \(claude ?? "—")"
    }

    /// Our own double-column gauge, distinct from both the OpenAI knot and Claude's star.
    static let customUsageIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.labelColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: 2, y: 3, width: 5, height: 12), xRadius: 1.5, yRadius: 1.5).fill()
            NSBezierPath(roundedRect: NSRect(x: 10, y: 3, width: 5, height: 8), xRadius: 1.5, yRadius: 1.5).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
