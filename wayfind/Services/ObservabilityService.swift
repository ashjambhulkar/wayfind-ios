import Foundation

#if canImport(Sentry)
import Sentry
#endif

enum ObservabilityService {
    enum Level: String {
        case info
        case warning
        case error
    }

    private static let maxStringLength = 240
    private static let maxContextFields = 16
    private static let blockedKeyFragments = [
        "authorization",
        "body",
        "email",
        "invite",
        "jwt",
        "key",
        "llm",
        "payload",
        "prompt",
        "request",
        "response",
        "secret",
        "token",
        "url",
    ]
    private static let expectedReasons = [
        "auth_cancelled",
        "daily_safety_cap_reached",
        "invalid_input",
        "invalid_json",
        "method_not_allowed",
        "no_session",
        "not_found",
        "quota_exceeded",
        "user_cancelled",
    ]

    static func configure() {
        guard AppConfig.isSentryConfigured else { return }

        #if canImport(Sentry)
        SentrySDK.start { options in
            options.dsn = AppConfig.sentryDSN
            options.environment = AppConfig.sentryEnvironment
            options.tracesSampleRate = NSNumber(value: AppConfig.sentryTraceSampleRate)
            options.sendDefaultPii = false
            options.attachStacktrace = true
            options.debug = false
            options.beforeSend = { event in
                let reason = event.tags?["wayfind.reason"]?.lowercased()
                return reason.map(isExpected(reason:)) == true ? nil : event
            }
        }
        #endif
    }

    static func setUser(id: UUID) {
        setUser(id: id.uuidString.lowercased())
    }

    static func setUser(id: String) {
        guard AppConfig.isSentryConfigured else { return }

        #if canImport(Sentry)
        SentrySDK.setUser(Sentry.User(userId: id))
        #endif
    }

    static func clearUser() {
        guard AppConfig.isSentryConfigured else { return }

        #if canImport(Sentry)
        SentrySDK.setUser(nil)
        #endif
    }

    static func breadcrumb(
        _ event: String,
        category: String,
        level: Level = .info,
        context: [String: Any] = [:]
    ) {
        guard AppConfig.isSentryConfigured else { return }
        let sanitized = sanitize(context)

        #if canImport(Sentry)
        let crumb = Breadcrumb()
        crumb.category = category
        crumb.message = truncate(event)
        crumb.level = sentryLevel(level)
        if !sanitized.isEmpty {
            crumb.data = sanitized
        }
        SentrySDK.addBreadcrumb(crumb)
        #endif
    }

    static func capture(
        error: Error,
        domain: String,
        reason: String,
        level: Level = .error,
        context: [String: Any] = [:]
    ) {
        guard AppConfig.isSentryConfigured else { return }
        guard !isExpected(reason: reason) else {
            breadcrumb(reason, category: domain, level: .info, context: context)
            return
        }

        let sanitized = sanitize(context)

        #if canImport(Sentry)
        SentrySDK.capture(error: error) { scope in
            scope.setLevel(sentryLevel(level))
            scope.setTag(value: domain, key: "wayfind.domain")
            scope.setTag(value: reason, key: "wayfind.reason")
            if !sanitized.isEmpty {
                scope.setContext(value: sanitized, key: "wayfind")
            }
        }
        #endif
    }

    static func captureMessage(
        _ message: String,
        domain: String,
        reason: String,
        level: Level = .warning,
        context: [String: Any] = [:]
    ) {
        guard AppConfig.isSentryConfigured else { return }
        guard !isExpected(reason: reason) else {
            breadcrumb(reason, category: domain, level: .info, context: context)
            return
        }

        let sanitized = sanitize(context)

        #if canImport(Sentry)
        SentrySDK.capture(message: truncate(message)) { scope in
            scope.setLevel(sentryLevel(level))
            scope.setTag(value: domain, key: "wayfind.domain")
            scope.setTag(value: reason, key: "wayfind.reason")
            if !sanitized.isEmpty {
                scope.setContext(value: sanitized, key: "wayfind")
            }
        }
        #endif
    }

    static func sanitize(_ context: [String: Any]) -> [String: Any] {
        var sanitized: [String: Any] = [:]
        for key in context.keys.sorted() {
            guard sanitized.count < maxContextFields else { break }
            let normalizedKey = key.lowercased()
            guard !blockedKeyFragments.contains(where: { normalizedKey.contains($0) }) else {
                continue
            }
            guard let value = sanitizedValue(context[key]) else { continue }
            sanitized[key] = value
        }
        return sanitized
    }

    private static func sanitizedValue(_ value: Any?) -> Any? {
        switch value {
        case let value as String:
            return truncate(value)
        case let value as UUID:
            return value.uuidString.lowercased()
        case let value as Int:
            return value
        case let value as Double where value.isFinite:
            return value
        case let value as Float where value.isFinite:
            return Double(value)
        case let value as Bool:
            return value
        case let value as Date:
            return ISO8601DateFormatter().string(from: value)
        default:
            return nil
        }
    }

    private static func truncate(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxStringLength else { return trimmed }
        return String(trimmed.prefix(maxStringLength))
    }

    private static func isExpected(reason: String) -> Bool {
        expectedReasons.contains(reason.lowercased())
    }

    #if canImport(Sentry)
    private static func sentryLevel(_ level: Level) -> SentryLevel {
        switch level {
        case .info:
            return .info
        case .warning:
            return .warning
        case .error:
            return .error
        }
    }

    #endif
}
