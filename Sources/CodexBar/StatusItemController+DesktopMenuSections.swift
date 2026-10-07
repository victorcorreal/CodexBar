import AppKit
import CodexBarCore

extension StatusItemController {
    func addDesktopAwareUsageHistory(to menu: NSMenu, context: MenuCardContext) {
        // Provider-specific by design: Claude Desktop bars replace the independently sourced CLI plan history.
        if context.currentProvider == .claude,
           self.settings.userDefaults.bool(forKey: "customDesktopMenuBarEnabled") { return }
        self.addUsageHistoryClusterIfNeeded(to: menu, context: context)
    }

    func desktopMenuSections(
        _ sections: [MenuDescriptor.Section], provider: UsageProvider?) -> [MenuDescriptor.Section]
    {
        // Provider-specific by design: the custom Claude Desktop menu keeps only usage, account switching and refresh.
        let minimal = provider == .claude && self.settings.userDefaults.bool(forKey: "customDesktopMenuBarEnabled")
        return Self.desktopMenuSections(sections, minimal: minimal)
    }

    static func desktopMenuSections(
        _ sections: [MenuDescriptor.Section], minimal: Bool) -> [MenuDescriptor.Section]
    {
        guard minimal else { return sections.filter { $0.entries.contains(where: \.isActionable) } }
        let refresh = sections.flatMap(\.entries).filter { entry in
            if case .action(_, .refresh) = entry { return true }
            return false
        }
        return refresh.isEmpty ? [] : [.init(entries: refresh)]
    }
}
