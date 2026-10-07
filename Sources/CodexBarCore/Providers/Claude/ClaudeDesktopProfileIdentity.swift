import Foundation

#if os(macOS)
import CommonCrypto
import Security

/// Borrows Desktop's access token for identity only. Never refreshes or writes its credentials.
public enum ClaudeDesktopProfileIdentity {
    public struct Identity: Equatable, Sendable {
        public let accountID: String
        public let email: String
    }

    public enum Failure: LocalizedError {
        case signedOut, permissionRequired, stale, invalidCache, accountChanged

        public var errorDescription: String? {
            switch self {
            case .signedOut: "Sign in to this profile in Claude."
            case .permissionRequired: "Allow CodexBar to read Claude Safe Storage to verify the email."
            case .stale: "Open Claude to renew this profile's login."
            case .invalidCache: "Claude's login format could not be read."
            case .accountChanged: "Claude's account changed. Open the menu again."
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

    public static func read(directory: URL, allowInteraction: Bool = false) async throws -> Identity {
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
        let status = SecItemCopyMatching(query as CFDictionary, &result)
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
        let tokens = entries.compactMap { cacheKey, value -> (String, Double)? in
            guard cacheKey.contains(":api.anthropic.com:"), cacheKey.contains("user:profile"),
                  let entry = value as? [String: Any], let token = entry["token"] as? String,
                  let expires = entry["expiresAt"] as? Double,
                  expires > Date().timeIntervalSince1970 * 1000 + 30000
            else { return nil }
            return (token, expires)
        }.sorted { $0.1 > $1.1 }
        guard let token = tokens.first?.0 else { throw Failure.stale }
        let response = try await ClaudeOAuthUsageFetcher.fetchProfile(accessToken: token)
        guard let identity = self.verifiedIdentity(
            expectedAccountID: owner, responseAccountID: response.accountUuid, email: response.emailAddress),
            try self.accountID(directory: directory) == owner
        else { throw Failure.accountChanged }
        return identity
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
