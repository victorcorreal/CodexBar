import Foundation

#if os(macOS)
extension ClaudeDesktopProfileIdentity {
    public struct Limit: Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let usedPercent: Double
        public let resetsAt: Date?
    }

    public struct ExtraUsage: Equatable, Sendable {
        public let used: Double
        public let limit: Double
        public let currency: String
    }

    static func weeklyLimits(response: OAuthUsageResponse) throws -> [Limit] {
        var result: [Limit] = []
        var seen: Set<String> = []
        for entry in response.limits ?? [] where entry.group == "weekly" {
            let id = entry.scope?.model?.id ?? entry.scope?.model?.displayName ?? entry.kind ?? "weekly"
            let title = entry.scope?.model?.displayName ?? entry.scope?.model?.id ?? "Semana"
            guard seen.insert(id).inserted else { continue }
            guard let percent = entry.percent, percent.isFinite, (0...100).contains(percent) else {
                throw Failure.usageUnavailable
            }
            result.append(Limit(id: id, title: title, usedPercent: percent, resetsAt: self.limitReset(entry.resetsAt)))
        }
        // Older responses return named weekly windows instead of the limits array.
        if result.isEmpty {
            let legacy: [(String, String, OAuthUsageWindow?)] = [
                ("weekly", "Semana", response.sevenDay),
                ("opus", "Opus", response.sevenDayOpus),
                ("sonnet", "Sonnet", response.sevenDaySonnet),
                ("oauth-apps", "Apps OAuth", response.sevenDayOAuthApps),
                ("routines", "Rutinas", response.sevenDayRoutines),
            ]
            for (id, title, window) in legacy {
                guard let window, let percent = window.utilization else { continue }
                guard percent.isFinite, (0...100).contains(percent) else { throw Failure.usageUnavailable }
                result.append(Limit(
                    id: id,
                    title: title,
                    usedPercent: percent,
                    resetsAt: self.limitReset(window.resetsAt)))
            }
        }
        return result
    }

    static func extraUsage(_ response: OAuthExtraUsage?) throws -> ExtraUsage? {
        guard let response, response.isEnabled == true else { return nil }
        guard let used = response.usedCredits, let limit = response.monthlyLimit else { return nil }
        guard used.isFinite, limit.isFinite, used >= 0, limit >= 0 else { throw Failure.usageUnavailable }
        guard limit > 0 else { return nil }
        let currency = response.currency?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ExtraUsage(
            used: used / 100,
            limit: limit / 100,
            currency: currency?.isEmpty == false ? currency! : "USD")
    }

    static func limitReset(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
#endif
