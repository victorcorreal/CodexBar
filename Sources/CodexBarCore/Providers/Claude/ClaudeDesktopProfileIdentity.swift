import Foundation

// Desktop cache handling adapted from OpenUsage. See Resources/OpenUsage-MIT.txt for its MIT notice.

#if os(macOS)
import CommonCrypto
import CryptoKit
import Security
import SQLite3

/// Borrows Desktop's access token for identity and usage. Never refreshes or writes its credentials.
public enum ClaudeDesktopProfileIdentity {
    public struct Identity: Equatable, Sendable {
        public let accountID: String
        public let email: String
    }

    public enum Failure: LocalizedError {
        case signedOut, permissionRequired, stale, invalidCache, accountChanged, usageUnavailable

        public var errorDescription: String? {
            switch self {
            case .signedOut: "Sign in to this profile in Claude."
            case .permissionRequired: "Allow CodexBar to read Claude Safe Storage to verify the account and its usage."
            case .stale: "Open Claude to renew this profile's login."
            case .invalidCache: "Claude's login format could not be read."
            case .accountChanged: "Claude's account changed. Open the menu again."
            case .usageUnavailable: "Claude did not return a current session usage limit."
            }
        }
    }

    public static func accountID(directory: URL) throws -> String? {
        let url = directory.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw Failure.invalidCache
        }
        guard let accountID = root["lastKnownAccountUuid"] as? String else { return nil }
        guard UUID(uuidString: accountID) != nil else { throw Failure.invalidCache }
        return accountID.lowercased()
    }

    public struct Usage: Equatable, Sendable {
        public let identity: Identity
        public let usedPercent: Double
        public let resetsAt: Date?
        public let fetchedAt: Date
    }

    public static func read(directory: URL, allowInteraction: Bool = false) async throws -> Identity {
        let session = try self.session(directory: directory, allowInteraction: allowInteraction)
        return try await self.verify(session: session, directory: directory)
    }

    public static func readUsage(directory: URL, allowInteraction: Bool = false) async throws -> Usage {
        let session = try self.session(directory: directory, allowInteraction: allowInteraction)
        let identity = try await self.verify(session: session, directory: directory)
        let response = try await ClaudeOAuthUsageFetcher.fetchUsage(
            accessToken: session.token, detectClaudeVersion: false)
        guard try self.accountID(directory: directory) == session.owner,
              try self.activeOrganization(directory: directory, key: session.key) == session.organization
        else { throw Failure.accountChanged }
        return try self.usage(response: response, identity: identity)
    }

    static func usage(response: OAuthUsageResponse, identity: Identity, now: Date = Date()) throws -> Usage {
        let sessionLimit = response.limits?.first { $0.kind == "session" }
        let percent = sessionLimit?.percent ?? response.fiveHour?.utilization
        guard let percent, percent.isFinite, percent >= 0, percent <= 100 else { throw Failure.usageUnavailable }
        let reset = sessionLimit?.resetsAt ?? response.fiveHour?.resetsAt
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let resetsAt = reset.flatMap { value -> Date? in
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        }
        return Usage(identity: identity, usedPercent: percent, resetsAt: resetsAt, fetchedAt: now)
    }

    private struct Session {
        let owner: String
        let organization: String
        let token: String
        let key: Data
    }

    private static func verify(session: Session, directory: URL) async throws -> Identity {
        let response = try await ClaudeOAuthUsageFetcher.fetchProfile(accessToken: session.token)
        guard let identity = self.verifiedIdentity(
            expectedAccountID: session.owner, responseAccountID: response.accountUuid, email: response.emailAddress),
            response.organizationUuid?.lowercased() == session.organization,
            try self.accountID(directory: directory) == session.owner,
            try self.activeOrganization(directory: directory, key: session.key) == session.organization
        else { throw Failure.accountChanged }
        return identity
    }

    private static func session(directory: URL, allowInteraction: Bool) throws -> Session {
        guard let owner = try self.accountID(directory: directory) else { throw Failure.signedOut }
        guard !KeychainTestSafety.shouldBlockRealKeychainAccess() else { throw Failure.permissionRequired }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Safe Storage",
            kSecAttrAccount as String: "Claude Key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if !allowInteraction { KeychainNoUIQuery.apply(to: &query) }
        var result: CFTypeRef?
        let status = KeychainSecurity.copyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let passwordData = result as? Data else {
            throw Failure.permissionRequired
        }
        let key = try self.deriveKey(password: passwordData)
        let root = try JSONSerialization.jsonObject(
            with: Data(contentsOf: directory.appendingPathComponent("config.json"))) as? [String: Any]
        var entries: [String: Any] = [:]
        for cacheName in ["oauth:tokenCache", "oauth:tokenCacheV2"] {
            guard let encoded = root?[cacheName] as? String else { continue }
            guard let encrypted = Data(base64Encoded: encoded),
                  let cache = try JSONSerialization.jsonObject(
                      with: self.decrypt(encrypted, key: key)) as? [String: Any]
            else { throw Failure.invalidCache }
            // V2 and account-scoped tombstones replace older entries.
            entries.merge(self.ownedEntries(cache, accountID: owner)) { _, newer in newer }
        }
        guard let organization = try self.activeOrganization(directory: directory, key: key) else {
            throw Failure.signedOut
        }
        guard let token = self.selectToken(entries: entries, organization: organization) else { throw Failure.stale }
        return Session(owner: owner, organization: organization, token: token, key: key)
    }

    static func selectToken(entries: [String: Any], organization: String, now: Date = Date()) -> String? {
        let marker = ":https://api.anthropic.com:"
        return entries.compactMap { cacheKey, value -> (String, Int, Double)? in
            guard let range = cacheKey.range(of: marker) else { return nil }
            let prefix = cacheKey[..<range.lowerBound].split(separator: ":")
            let scopes = cacheKey[range.upperBound...].split(separator: " ")
            guard prefix.count == 2, UUID(uuidString: String(prefix[0])) != nil,
                  prefix[1].lowercased() == organization.lowercased(), scopes.contains("user:profile"),
                  let entry = value as? [String: Any], let token = entry["token"] as? String, !token.isEmpty,
                  let expires = entry["expiresAt"] as? Double, expires.isFinite,
                  expires > now.timeIntervalSince1970 * 1000 + 30000
            else { return nil }
            let production = prefix[0] == "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
            let rank = (scopes.contains("user:inference") ? 100 : 0) + (production ? 10 : 0) + scopes.count
            return (token, rank, expires)
        }.max { ($0.1, $0.2) < ($1.1, $1.2) }?.0
    }

    /// Detect organization changes without decrypting cookies or touching the Keychain.
    public static func organizationFingerprint(directory: URL) throws -> String? {
        for path in ["Cookies", "Network/Cookies"] {
            let url = directory.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            var database: OpaquePointer?
            guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                if let database { sqlite3_close(database) }
                throw Failure.invalidCache
            }
            defer { sqlite3_close(database) }
            sqlite3_busy_timeout(database, 100)
            let sql = """
            SELECT host_key, value, encrypted_value FROM cookies
            WHERE name = 'lastActiveOrg' AND host_key IN ('.claude.ai', 'claude.ai')
            ORDER BY last_update_utc DESC
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw Failure.invalidCache
            }
            defer { sqlite3_finalize(statement) }
            var payload = Data()
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                for column in 0...2 {
                    if let bytes = sqlite3_column_blob(statement, Int32(column)) {
                        payload.append(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, Int32(column)))))
                    }
                    payload.append(0)
                }
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { throw Failure.invalidCache }
            if !payload.isEmpty { return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined() }
        }
        return nil
    }

    private static func activeOrganization(directory: URL, key: Data) throws -> String? {
        for path in ["Cookies", "Network/Cookies"] {
            let url = directory.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            var database: OpaquePointer?
            guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                if let database { sqlite3_close(database) }
                throw Failure.invalidCache
            }
            defer { sqlite3_close(database) }
            sqlite3_busy_timeout(database, 100)
            let sql = """
            SELECT host_key, value, encrypted_value FROM cookies
            WHERE name = 'lastActiveOrg' AND host_key IN ('.claude.ai', 'claude.ai')
            ORDER BY last_update_utc DESC
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw Failure.invalidCache
            }
            defer { sqlite3_finalize(statement) }
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                guard let hostBytes = sqlite3_column_text(statement, 0),
                      let valueBytes = sqlite3_column_text(statement, 1) else { throw Failure.invalidCache }
                let host = String(cString: hostBytes)
                let plain = String(cString: valueBytes)
                let organization: String?
                if !plain.isEmpty {
                    organization = plain
                } else if let bytes = sqlite3_column_blob(statement, 2) {
                    let encrypted = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 2)))
                    let decrypted = try self.decrypt(encrypted, key: key)
                    let hash = Data(SHA256.hash(data: Data(host.utf8)))
                    guard decrypted.starts(with: hash) else { throw Failure.invalidCache }
                    organization = String(data: decrypted.dropFirst(hash.count), encoding: .utf8)
                } else {
                    organization = nil
                }
                if let organization, UUID(uuidString: organization) != nil { return organization.lowercased() }
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { throw Failure.invalidCache }
        }
        return nil
    }

    static func verifiedIdentity(
        expectedAccountID: String, responseAccountID: String?, email: String?) -> Identity?
    {
        guard let responseAccountID, responseAccountID.lowercased() == expectedAccountID.lowercased(),
              let email = email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty
        else { return nil }
        return Identity(accountID: expectedAccountID.lowercased(), email: email)
    }

    static func ownedEntries(_ cache: [String: Any], accountID: String) -> [String: Any] {
        var legacy: [String: Any] = [:]
        var scoped: [String: Any] = [:]
        for (rawKey, entry) in cache {
            guard rawKey.hasPrefix("acct:") else {
                legacy[rawKey] = entry
                continue
            }
            let parts = rawKey.split(separator: "|", maxSplits: 1)
            guard parts.count == 2, parts[0].dropFirst(5).lowercased() == accountID.lowercased() else { continue }
            scoped[String(parts[1])] = entry
        }
        return legacy.merging(scoped) { _, owned in owned }
    }

    private static func deriveKey(password: Data) throws -> Data {
        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let status = key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        password.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        kCCKeySizeAES128)
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.invalidCache }
        return key
    }

    private static func decrypt(_ encrypted: Data, key: Data) throws -> Data {
        guard encrypted.count > 3, encrypted.prefix(3) == Data("v10".utf8) else { throw Failure.invalidCache }
        let payload = encrypted.dropFirst(3)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: payload.count + kCCBlockSizeAES128)
        let capacity = output.count
        var length = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            payload.withUnsafeBytes { payloadBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            payloadBytes.baseAddress,
                            payload.count,
                            outputBytes.baseAddress,
                            capacity,
                            &length)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.invalidCache }
        output.count = length
        return output
    }
}
#endif
