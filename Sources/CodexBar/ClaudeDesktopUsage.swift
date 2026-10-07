import AppKit
import CodexBarCore

/// Keeps Desktop usage separate from Claude Code's independently selected CLI account.
@MainActor
final class ClaudeDesktopUsage {
    static let shared = ClaudeDesktopUsage()

    struct Context: Equatable {
        let directory: URL
        let accountID: String
        let processID: pid_t
        let organizationFingerprint: String?
    }

    private(set) var context: Context?
    private(set) var usage: ClaudeDesktopProfileIdentity.Usage?
    private(set) var error: String?
    private var lastAttempt = Date.distantPast
    private var monitor: Task<Void, Never>?
    private var request: Task<Void, Never>?
    var didChange: (() -> Void)?
    private let logger = CodexBarLog.logger(LogCategories.app)

    func start() {
        guard self.monitor == nil, !TestProcessSafety.isRunning else { return }
        self.monitor = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }

    func currentContext() throws -> Context? {
        let profiles = ClaudeDesktopProfiles.shared
        let running = try profiles.running()
        // A single shared bar cannot unambiguously describe two simultaneous Desktop accounts.
        guard running.count <= 1 else {
            throw NSError(domain: "ClaudeDesktopUsage", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Several Claude accounts are open. Keep one open to show its usage.",
            ])
        }
        guard let active = running.first else { return nil }
        let directory = profiles.directory(for: active.profileID)
        guard let owner = try ClaudeDesktopProfileIdentity.accountID(directory: directory) else { return nil }
        return try Context(
            directory: directory,
            accountID: owner,
            processID: active.processID,
            organizationFingerprint: ClaudeDesktopProfileIdentity.organizationFingerprint(directory: directory))
    }

    func refresh(allowInteraction: Bool = false) {
        do {
            let current = try self.currentContext()
            if current != self.context {
                self.request?.cancel()
                self.request = nil
                self.context = current
                self.usage = nil
                self.error = nil
                self.lastAttempt = .distantPast
                self.didChange?()
            }
            // Expiration also updates the bar when no provider-store event occurs.
            self.didChange?()
            guard let current, self.request == nil,
                  allowInteraction || Date().timeIntervalSince(self.lastAttempt) >= 60 else { return }
            self.lastAttempt = Date()
            self.request = Task {
                defer {
                    if !Task.isCancelled {
                        self.request = nil
                        self.didChange?()
                    }
                }
                do {
                    let result = try await ClaudeDesktopProfileIdentity.readUsage(
                        directory: current.directory, allowInteraction: allowInteraction)
                    guard !Task.isCancelled else { return }
                    let live = try self.currentContext()
                    guard self.accept(result, requested: current, live: live) else { return }
                    ClaudeDesktopProfiles.shared.acceptIdentity(result.identity, directory: current.directory)
                    self.logger
                        .info("Claude Desktop session usage refreshed: \(Int(result.usedPercent.rounded()))% used")
                } catch {
                    guard !Task.isCancelled else { return }
                    self.usage = nil
                    self.error = error.localizedDescription
                    self.logger.error("Claude Desktop usage failed: \(error.localizedDescription)")
                }
            }
        } catch {
            self.request?.cancel()
            self.request = nil
            self.context = nil
            self.usage = nil
            self.error = error.localizedDescription
            self.logger.error("Claude Desktop usage detection failed: \(error.localizedDescription)")
            self.didChange?()
        }
    }

    @discardableResult
    func accept(
        _ result: ClaudeDesktopProfileIdentity.Usage,
        requested: Context,
        live: Context?) -> Bool
    {
        guard requested == live, result.identity.accountID == requested.accountID else {
            self.context = live
            self.usage = nil
            self.error = "Claude's account changed. Waiting for current usage."
            self.lastAttempt = .distantPast
            return false
        }
        self.context = live
        self.usage = result
        self.error = nil
        return true
    }

    func percentText(showUsed: Bool, now: Date = Date()) -> String? {
        guard let usage, usage.identity.accountID == self.context?.accountID,
              now.timeIntervalSince(usage.fetchedAt) >= 0,
              now.timeIntervalSince(usage.fetchedAt) < 120,
              usage.resetsAt.map({ $0 > now }) ?? true else { return nil }
        let percent = showUsed ? usage.usedPercent : 100 - usage.usedPercent
        return "\(Int(percent.rounded()))%"
    }
}
