import AppKit
import CodexBarCore

extension StatusItemController {
    var desktopOverviewOnly: Bool {
        self.settings.userDefaults.bool(forKey: "customDesktopMenuBarEnabled")
    }

    func addDesktopAwareOverviewRows(
        to menu: NSMenu,
        enabledProviders: [UsageProvider],
        menuWidth: CGFloat,
        captureMenu: NSMenu? = nil) -> Bool
    {
        guard self.settings.userDefaults.bool(forKey: "customDesktopMenuBarEnabled") else {
            return self.addOverviewRows(
                to: menu, enabledProviders: enabledProviders, menuWidth: menuWidth, captureMenu: captureMenu)
        }
        var added = false
        for provider in enabledProviders {
            if added, menu.items.last?.isSeparatorItem != true { menu.addItem(.separator()) }
            // Provider-specific by design: Overview uses the active Desktop account instead of Claude CLI credentials.
            if provider == .claude {
                let context = MenuCardContext(
                    currentProvider: provider,
                    selectedProvider: provider,
                    menuWidth: menuWidth,
                    codexAccountDisplay: nil,
                    tokenAccountDisplay: nil,
                    openAIContext: .init(
                        hasUsageBreakdown: false,
                        hasCreditsHistory: false,
                        hasCostHistory: false,
                        canShowBuyCredits: false,
                        hasOpenAIWebMenuItems: false))
                added = self.addClaudeDesktopUsageCard(to: menu, context: context) || added
                self.addClaudeDesktopProfiles(to: menu, provider: provider)
            } else if let model = self.menuCardModel(for: provider) {
                let rendered = self.menuCardRefreshMonitor.model(for: model.provider, fallback: model)
                menu.addItem(self.makeMenuCardItem(
                    UsageMenuCardView(model: model, layoutModel: rendered, width: menuWidth),
                    id: "desktopOverview-\(provider.rawValue)",
                    width: menuWidth,
                    containsInteractiveControls: true))
                added = true
            }
        }
        while menu.items.last?.isSeparatorItem == true {
            menu.removeItem(at: menu.numberOfItems - 1)
        }
        return added
    }
}
