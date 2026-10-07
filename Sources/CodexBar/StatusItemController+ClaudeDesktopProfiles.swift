import AppKit
import CodexBarCore

extension StatusItemController {
    func addClaudeDesktopProfiles(to menu: NSMenu, provider: UsageProvider) {
        // Provider-specific by design: this selector manages Claude Desktop's isolated Electron profiles.
        guard provider == .claude else { return }
        let profiles = ClaudeDesktopProfiles.shared
        profiles.didChange = { [weak self] in self?.refreshOpenMenusAfterExplicitStoreAction() }
        let submenu = NSMenu(title: "Claude Desktop Accounts")
        do {
            let running = try profiles.running()
            let foregroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let active = running.first { $0.processID == foregroundPID } ?? running.first
            let title: String
            if let active {
                let label = profiles.email(for: active.profileID) ?? profiles.name(for: active.profileID)
                title = "Claude Desktop: \(label)"
                profiles.verifyIdentity(for: active.profileID)
            } else {
                title = "Claude Desktop: Closed"
            }
            let displayTitle = PersonalInfoRedactor.redactEmails(
                in: title, isEnabled: self.settings.hidePersonalInfo) ?? title
            let parent = NSMenuItem(title: displayTitle, action: nil, keyEquivalent: "")
            parent.submenu = submenu
            menu.addItem(parent)
            let rows: [(UUID?, String)] = [(nil, "Existing Claude")] + profiles.profiles.map {
                (Optional($0.id), $0.name)
            }
            for (id, name) in rows {
                let email = profiles.email(for: id)
                let label = email.map { "\(name) · \($0)" } ?? name
                let displayLabel = PersonalInfoRedactor.redactEmails(
                    in: label, isEnabled: self.settings.hidePersonalInfo) ?? label
                let item = NSMenuItem(
                    title: displayLabel,
                    action: #selector(self.switchClaudeDesktopProfile(_:)),
                    keyEquivalent: "")
                item.target = self
                item.representedObject = id?.uuidString ?? "existing"
                item.state = running.contains { $0.profileID == id } ? .on : .off
                item.isEnabled = !profiles.isSwitching
                submenu.addItem(item)
            }
            if let active, profiles.email(for: active.profileID) == nil {
                submenu.addItem(.separator())
                let status = NSMenuItem(
                    title: profiles.identityError ?? "Verifying Account Email…", action: nil, keyEquivalent: "")
                status.isEnabled = false
                submenu.addItem(status)
                let verify = NSMenuItem(
                    title: "Verify Account Email…",
                    action: #selector(self.verifyClaudeDesktopEmail(_:)),
                    keyEquivalent: "")
                verify.target = self
                verify.representedObject = active.profileID?.uuidString ?? "existing"
                submenu.addItem(verify)
            }
        } catch {
            self.menuLogger.error("Claude Desktop account detection failed: \(error.localizedDescription)")
            let item = NSMenuItem(title: error.localizedDescription, action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
            let parent = NSMenuItem(title: "Claude Desktop: Account Unavailable", action: nil, keyEquivalent: "")
            parent.submenu = submenu
            menu.addItem(parent)
        }
        submenu.addItem(.separator())
        let add = NSMenuItem(
            title: "Add Claude Desktop Account…",
            action: #selector(self.addClaudeDesktopProfile(_:)),
            keyEquivalent: "")
        add.target = self
        add.isEnabled = !profiles.isSwitching
        submenu.addItem(add)
        menu.addItem(.separator())
    }

    @objc func switchClaudeDesktopProfile(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String,
              value == "existing" || UUID(uuidString: value) != nil
        else { return }
        let id = UUID(uuidString: value)
        Task {
            do {
                try await ClaudeDesktopProfiles.shared.launch(id: id)
            } catch {
                self.showClaudeDesktopProfileError(error)
            }
        }
    }

    @objc func verifyClaudeDesktopEmail(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String,
              value == "existing" || UUID(uuidString: value) != nil
        else { return }
        ClaudeDesktopProfiles.shared.verifyIdentity(for: UUID(uuidString: value), allowInteraction: true)
    }

    @objc func addClaudeDesktopProfile(_: NSMenuItem) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Add Claude Desktop Account"
        alert.informativeText = "Name this profile. Claude will reopen so you can sign in to the new account. "
            + "Each profile keeps its own login and conversations. Finish any active Code work before continuing."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "Personal or Work"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add and Open Claude")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let profile = try ClaudeDesktopProfiles.shared.create(name: field.stringValue)
            Task {
                do {
                    try await ClaudeDesktopProfiles.shared.launch(id: profile.id)
                } catch {
                    self.showClaudeDesktopProfileError(error)
                }
            }
        } catch {
            self.showClaudeDesktopProfileError(error)
        }
    }

    private func showClaudeDesktopProfileError(_ error: Error) {
        self.menuLogger.error("Claude Desktop profile action failed: \(error.localizedDescription)")
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Claude Desktop Account"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
