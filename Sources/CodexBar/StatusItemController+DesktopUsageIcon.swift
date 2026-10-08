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
        Task { await ClaudeDesktopProfiles.shared.restoreLastProfileIfClosed() }
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
            "desktopUsageLogos", text,
            String(self.shouldUseHighContrastStatusItemContent), String(self.settings.usageBarsShowUsed),
        ].joined(separator: "|")
        let skipped = self.shouldSkipMergedIconRender(signature)
        // Provider-specific by design: each number is identified by its own service logo.
        if let codexLogo = ProviderBrandIcon.image(for: .codex),
           let claudeLogo = ProviderBrandIcon.image(for: .claude)
        {
            button.attributedTitle = NSAttributedString(string: "")
            button.imagePosition = .imageOnly
            if !skipped || button.image == nil {
                button.image = Self.desktopUsageImage(
                    codex: codex, claude: claude, codexLogo: codexLogo, claudeLogo: claudeLogo)
            }
        } else {
            self.menuLogger.error("Desktop usage service logos could not be loaded")
            button.image = nil
            button.imagePosition = .noImage
            button.attributedTitle = NSAttributedString(string: text)
        }
        let direction = self.settings.usageBarsShowUsed ? "used" : "remaining"
        button
            .setAccessibilityLabel(
                "Codex \(codex ?? "unavailable"), Claude Desktop \(claude ?? "unavailable") \(direction)")
        return skipped
    }

    static func desktopUsageImage(
        codex: String?, claude: String?, codexLogo: NSImage, claudeLogo: NSImage) -> NSImage
    {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let codexText = (codex?.replacingOccurrences(of: "%", with: "") ?? "—") as NSString
        let claudeText = (claude?.replacingOccurrences(of: "%", with: "") ?? "—") as NSString
        let codexSize = codexText.size(withAttributes: attributes)
        let claudeSize = claudeText.size(withAttributes: attributes)
        let iconSize: CGFloat = 16
        let gap: CGFloat = 5
        let between: CGFloat = 12
        let height: CGFloat = 18
        let claudeX = iconSize + gap + codexSize.width + between
        let image = NSImage(size: NSSize(width: ceil(claudeX + iconSize + gap + claudeSize.width), height: height))
        image.lockFocus()
        codexLogo.draw(in: NSRect(x: 0, y: 1, width: iconSize, height: iconSize))
        codexText.draw(at: NSPoint(x: iconSize + gap, y: (height - codexSize.height) / 2), withAttributes: attributes)
        claudeLogo.draw(in: NSRect(x: claudeX, y: 1, width: iconSize, height: iconSize))
        claudeText.draw(
            at: NSPoint(x: claudeX + iconSize + gap, y: (height - claudeSize.height) / 2),
            withAttributes: attributes)
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    static func desktopUsageTitle(codex: String?, claude: String?) -> String {
        let codexNumber = codex?.replacingOccurrences(of: "%", with: "") ?? "—"
        let claudeNumber = claude?.replacingOccurrences(of: "%", with: "") ?? "—"
        return "Cdx \(codexNumber)  Cl \(claudeNumber)"
    }
}
