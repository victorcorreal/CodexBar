import AppKit
import CodexBarCore

@MainActor
final class ClaudeDesktopProfiles {
    static let shared = ClaudeDesktopProfiles(home: TestProcessSafety.isRunning
        ? FileManager.default.temporaryDirectory.appendingPathComponent("CodexBarDesktopTests-\(UUID().uuidString)")
        : FileManager.default.homeDirectoryForCurrentUser)

    struct Profile: Codable, Identifiable {
        let id: UUID
        let name: String
    }

    struct RunningProfile {
        let profileID: UUID?
        let processID: pid_t
    }

    struct RememberedIdentity: Codable {
        let accountID: String
        let email: String
    }

    struct RememberedState: Codable {
        var selected: String?
        var identities: [String: RememberedIdentity] = [:]
    }

    private var remembered = RememberedState()
    private let home: URL
    private let root: URL
    private(set) var profiles: [Profile] = []
    private(set) var isSwitching = false
    private var identities: [String: ClaudeDesktopProfileIdentity.Identity] = [:]
    private(set) var identityError: String?
    private var identityTask: Task<Void, Never>?
    private var lastVerification: [String: Date] = [:]
    private var lastAccountIDs: [String: String] = [:]
    private var storageError: Error?
    var didChange: (() -> Void)?
    private(set) var revision = 0
    private let logger = CodexBarLog.logger(LogCategories.app)

    init(home: URL) {
        self.home = home
        self.root = home.appendingPathComponent("Library/Application Support/CodexBar/ClaudeDesktopProfiles")
        do {
            let file = self.root.appendingPathComponent("profiles.json")
            if FileManager.default.fileExists(atPath: file.path) {
                self.profiles = try JSONDecoder().decode([Profile].self, from: Data(contentsOf: file))
            }
            let stateFile = self.root.appendingPathComponent("remembered.json")
            if FileManager.default.fileExists(atPath: stateFile.path) {
                self.remembered = try JSONDecoder().decode(RememberedState.self, from: Data(contentsOf: stateFile))
            }
        } catch {
            self.storageError = error
            self.identityError = "Could not load Claude profiles: \(error.localizedDescription)"
            self.logger.error("Claude Desktop profiles could not be loaded: \(error.localizedDescription)")
        }
    }

    func directory(for id: UUID?) -> URL {
        guard let id else { return self.home.appendingPathComponent("Library/Application Support/Claude") }
        return self.root.appendingPathComponent(id.uuidString).appendingPathComponent("desktop")
    }

    func name(for id: UUID?) -> String {
        self.profiles.first { $0.id == id }?.name ?? "Claude Principal"
    }

    func create(name: String) throws -> Profile {
        if let storageError = self.storageError { throw storageError }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, !name.contains(where: \.isNewline) else {
            throw NSError(domain: "ClaudeDesktopProfiles", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Enter a profile name of 1–80 characters.",
            ])
        }
        let profile = Profile(id: UUID(), name: name)
        let profileRoot = self.root.appendingPathComponent(profile.id.uuidString)
        try FileManager.default.createDirectory(
            at: profileRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(
            at: self.directory(for: profile.id),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(
            at: profileRoot.appendingPathComponent("code"),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let updated = self.profiles + [profile]
        try JSONEncoder().encode(updated).write(to: self.root.appendingPathComponent("profiles.json"), options: .atomic)
        self.profiles = updated
        self.revision += 1
        self.didChange?()
        return profile
    }

    /// Match only Claude's main executable. Helpers and similarly named folders are excluded.
    static func profileID(command: String, directories: [(UUID?, String)]) -> UUID?? {
        guard command.hasPrefix("/Applications/Claude.app/Contents/MacOS/Claude"),
              command == "/Applications/Claude.app/Contents/MacOS/Claude"
              || command.hasPrefix("/Applications/Claude.app/Contents/MacOS/Claude --")
        else { return nil }
        let marker = command.range(of: " --user-data-dir=") ?? command.range(of: " --user-data-dir ")
        guard let marker else { return .some(nil) }
        let remainder = String(command[marker.upperBound...])
        for (id, path) in directories where remainder == path || remainder.hasPrefix(path + " --") {
            return .some(id)
        }
        return nil
    }

    func running() throws -> [RunningProfile] {
        guard !TestProcessSafety.isRunning else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ClaudeDesktopProfiles", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not detect running Claude accounts.",
            ])
        }
        let directories = [(nil as UUID?, self.directory(for: nil).path)] + self.profiles.map {
            (Optional($0.id), self.directory(for: $0.id).path)
        }
        guard let output = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "ClaudeDesktopProfiles", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "Claude process information could not be decoded.",
            ])
        }
        return try output.split(separator: "\n").compactMap { line in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let pid = pid_t(parts[0]) else { return nil }
            let command = String(parts[1])
            guard let profile = Self.profileID(command: command, directories: directories) else {
                if command.hasPrefix("/Applications/Claude.app/Contents/MacOS/Claude --") {
                    throw NSError(domain: "ClaudeDesktopProfiles", code: 5, userInfo: [
                        NSLocalizedDescriptionKey: "Claude is running with an unrecognized profile.",
                    ])
                }
                return nil
            }
            return RunningProfile(profileID: profile, processID: pid)
        }
    }

    func acceptIdentity(_ identity: ClaudeDesktopProfileIdentity.Identity, directory: URL) {
        guard (try? ClaudeDesktopProfileIdentity.accountID(directory: directory)) == identity.accountID else { return }
        self.identities[directory.path] = identity
        self.remembered.identities[self.stateKey(directory: directory)] = RememberedIdentity(
            accountID: identity.accountID, email: identity.email)
        do { try self.saveRememberedState() } catch {
            self.identityError = "Could not remember Claude account: \(error.localizedDescription)"
            self.logger.error("Claude account persistence failed: \(error.localizedDescription)")
        }
        self.revision += 1
        self.didChange?()
    }

    func email(for id: UUID?) -> String? {
        let directory = self.directory(for: id)
        guard let owner = try? ClaudeDesktopProfileIdentity.accountID(directory: directory),
              let identity = self.remembered.identities[self.stateKey(directory: directory)],
              identity.accountID == owner
        else { return nil }
        return identity.email
    }

    func verifyIdentity(for id: UUID?, allowInteraction: Bool = false) {
        guard self.identityTask == nil else { return }
        let directory = self.directory(for: id)
        let owner = try? ClaudeDesktopProfileIdentity.accountID(directory: directory)
        let retryDelay: TimeInterval = self.email(for: id) == nil ? 5 : 60
        if !allowInteraction, let last = self.lastVerification[directory.path],
           self.lastAccountIDs[directory.path] == owner,
           Date().timeIntervalSince(last) < retryDelay
        { return }
        self.lastVerification[directory.path] = Date()
        self.lastAccountIDs[directory.path] = owner
        self.identityTask = Task {
            defer {
                self.identityTask = nil
                self.revision += 1
                self.didChange?()
            }
            do {
                let identity = try await ClaudeDesktopProfileIdentity.read(
                    directory: directory, allowInteraction: allowInteraction)
                self.identityError = nil
                self.acceptIdentity(identity, directory: directory)
            } catch {
                self.identities.removeValue(forKey: directory.path)
                self.identityError = error.localizedDescription
                self.logger.error("Claude Desktop identity verification failed: \(error.localizedDescription)")
            }
        }
    }

    func launch(id: UUID?, onlyIfClosed: Bool = false) async throws {
        guard !TestProcessSafety.isRunning else {
            throw NSError(domain: "ClaudeDesktopProfiles", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Live Claude launches are disabled in tests.",
            ])
        }
        guard !self.isSwitching else { return }
        guard id == nil || self.profiles.contains(where: { $0.id == id }) else { return }
        let appURL = URL(fileURLWithPath: "/Applications/Claude.app")
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw NSError(domain: "ClaudeDesktopProfiles", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Install Claude in Applications first.",
            ])
        }
        self.isSwitching = true
        defer { self.isSwitching = false }
        let running = try self.running()
        if onlyIfClosed, !running.isEmpty { return }
        if let selected = running.first(where: { $0.profileID == id }),
           let app = NSRunningApplication(processIdentifier: selected.processID)
        {
            app.activate()
            try self.rememberSelection(id: id)
            return
        }
        // Ask Claude to quit normally. Never force-kill an active Code session.
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop")
        for app in apps {
            app.terminate()
        }
        // Workspace termination flags can lag behind the main process exiting.
        // Claude may also need more than eight seconds to finish its Code cleanup.
        let closed = try await Self.waitForQuit(isClosed: { try self.running().isEmpty })
        guard closed else {
            throw NSError(domain: "ClaudeDesktopProfiles", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Claude is taking longer to quit. Finish any active Code work. "
                    + "Once Claude closes, select this saved account again.",
            ])
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--user-data-dir=\(self.directory(for: id).path)"]
        if let id {
            let codeDirectory = self.root.appendingPathComponent(id.uuidString).appendingPathComponent("code")
            configuration.environment = ["CLAUDE_CONFIG_DIR": codeDirectory.path]
        }
        _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        try self.rememberSelection(id: id)
        self.revision += 1
        self.didChange?()
        self.verifyIdentity(for: id)
    }

    private func stateKey(directory: URL) -> String {
        if directory == self.directory(for: nil) { return "existing" }
        return directory.deletingLastPathComponent().lastPathComponent
    }

    private func saveRememberedState() throws {
        if let storageError = self.storageError { throw storageError }
        try FileManager.default.createDirectory(
            at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = self.root.appendingPathComponent("remembered.json")
        try JSONEncoder().encode(self.remembered).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func rememberSelection(id: UUID?) throws {
        guard id == nil || self.profiles.contains(where: { $0.id == id }) else {
            throw NSError(domain: "ClaudeDesktopProfiles", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "The saved Claude profile no longer exists.",
            ])
        }
        self.remembered.selected = id?.uuidString ?? "existing"
        try self.saveRememberedState()
    }

    var rememberedSelection: String? {
        self.remembered.selected
    }

    func restoreLastProfileIfClosed() async {
        guard !TestProcessSafety.isRunning, let selected = self.remembered.selected else { return }
        do {
            guard try self.running().isEmpty else { return }
            let id = selected == "existing" ? nil : UUID(uuidString: selected)
            guard selected == "existing" || id.map({ value in self.profiles.contains { $0.id == value } }) == true
            else {
                throw NSError(domain: "ClaudeDesktopProfiles", code: 8, userInfo: [
                    NSLocalizedDescriptionKey: "The saved Claude profile no longer exists.",
                ])
            }
            try await self.launch(id: id, onlyIfClosed: true)
        } catch {
            self.identityError = "Could not restore Claude account: \(error.localizedDescription)"
            self.logger.error("Claude profile restoration failed: \(error.localizedDescription)")
            self.didChange?()
        }
    }

    static func waitForQuit(
        pollLimit: Int = 120,
        isClosed: () throws -> Bool,
        pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(250)) }) async throws -> Bool
    {
        for _ in 0..<pollLimit {
            if try isClosed() { return true }
            try await pause()
        }
        return try isClosed()
    }
}
