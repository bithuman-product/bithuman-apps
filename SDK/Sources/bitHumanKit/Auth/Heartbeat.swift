import Foundation
#if canImport(IOKit)
import IOKit
#endif

// Heartbeat + authentication for metered use of the bitHuman Swift
// SDK. Mirrors the Python `AsyncBithuman` / expression-avatar
// billing flow so a customer with one `api_secret` gets consistent
// charging across Python on the server side and Swift on the client
// side:
//
//   POST https://api.bithuman.ai/v1/runtime-tokens/request
//     Headers: api-secret: <key>
//     Body:    { fingerprint, transaction_id, billing_type, tags }
//
//   Pricing:   self-hosted-expression-model → 2 credits / minute
//   Cadence:   every 60 seconds while a Bithuman runtime is alive
//   Fatal on:  HTTP 402 (insufficient balance) or 403 (suspended)
//
// The SDK runs the full lip-sync pipeline on-device, which is
// functionally equivalent to the self-hosted GPU container from a
// metering perspective — both consume 2 credits per active minute.
//
// If no `apiSecret` is supplied to `Bithuman.create(...)`, heartbeat
// is disabled entirely and the SDK runs unmetered (the current
// behavior for development + first-party consumers like Halo).

// MARK: - Config

/// Configuration for the heartbeat / billing client. Most fields
/// have sensible defaults; you only need to supply `apiSecret`.
public struct BithumanAuthConfig: Sendable {

    /// Developer API secret. Obtain at https://www.bithuman.ai → Developer → API Keys.
    public let apiSecret: String

    /// Stable per-machine identifier used by the billing system to
    /// deduplicate sessions. Defaults to a cached UUID stored under
    /// `UserDefaults` (`com.bithuman.sdk.fingerprint`) + the
    /// machine's IOPlatformUUID when available. Override only if you
    /// have a reason (e.g. per-user fingerprinting).
    public let fingerprint: String

    /// Heartbeat cadence. The auth-service buckets usage in 60-second
    /// increments; changing this won't change what you're charged but
    /// may affect how quickly over-balance termination takes effect.
    public let interval: TimeInterval

    /// Billing type string recognised by the auth-service. The Swift
    /// SDK uses `self-hosted-expression-model` (2 credits/minute) to
    /// match the self-hosted GPU container.
    public let billingType: String

    /// Free-form tag forwarded to the billing service. Useful for
    /// filtering usage reports (e.g. "halo-app", "my-agent", "ci").
    public let tags: String

    /// Full URL of the runtime-tokens endpoint. Override only for
    /// on-prem deployments of `api.bithuman.ai`.
    public let endpoint: URL

    public init(
        apiSecret: String,
        fingerprint: String = BithumanAuthConfig.defaultFingerprint(),
        interval: TimeInterval = 60,
        billingType: String = BithumanAuthConfig.selfHostedExpressionModel,
        tags: String = "swift-sdk",
        endpoint: URL = BithumanAuthConfig.defaultEndpoint
    ) {
        self.apiSecret = apiSecret
        self.fingerprint = fingerprint
        self.interval = interval
        self.billingType = billingType
        self.tags = tags
        self.endpoint = endpoint
    }

    // MARK: Constants

    /// The production runtime-tokens endpoint.
    public static let defaultEndpoint = URL(
        string: "https://api.bithuman.ai/v1/runtime-tokens/request"
    )!

    /// Billing type for the Swift SDK. The on-device Expression
    /// pipeline is metered identically to the self-hosted GPU
    /// container — 2 credits/minute.
    public static let selfHostedExpressionModel = "self-hosted-expression-model"

    /// Billing type for the on-device Essence runtime. Mirrors the
    /// `selfHostedExpressionModel` naming so the auth-service can route
    /// both runtimes through the same `self-hosted-*-model` family.
    /// The auth-service maps this string to the `model="essence"`
    /// branch (1 credit / minute), distinct from Expression's 2 cr/min.
    /// A platform-side change is queued to teach auth-service to
    /// recognize this string explicitly — until that lands, the
    /// `model="essence"` default branch covers it correctly.
    public static let selfHostedEssenceModel = "self-hosted-essence-model"

    // MARK: Fingerprint

    /// Build a stable 32-character hex fingerprint for this machine.
    ///
    /// Combines the macOS IOPlatformUUID (stable across installs) with
    /// a per-install UUID cached in UserDefaults. The UUID cache
    /// handles machines where IOPlatformUUID is unavailable (CI,
    /// sandboxed tests) without falling back to per-session randomness
    /// that would fragment billing into one activity per launch.
    public static func defaultFingerprint() -> String {
        let machine = platformUUID() ?? ""
        let installKey = "com.bithuman.sdk.fingerprint.install-id"
        let install: String
        if let cached = UserDefaults.standard.string(forKey: installKey) {
            install = cached
        } else {
            let fresh = UUID().uuidString
            UserDefaults.standard.set(fresh, forKey: installKey)
            install = fresh
        }
        let combined = "\(machine)::\(install)"
        return sha256Hex(combined).prefix(32).lowercased()
    }

    /// Read the macOS IOPlatformUUID. Returns nil on sandboxed
    /// environments that can't query IOKit.
    private static func platformUUID() -> String? {
        #if canImport(IOKit)
        let dict = IOServiceMatching("IOPlatformExpertDevice")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, dict)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let anyRef = IORegistryEntryCreateCFProperty(
            service,
            "IOPlatformUUID" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else {
            return nil
        }
        return anyRef as? String
        #else
        return nil
        #endif
    }

    private static func sha256Hex(_ s: String) -> String {
        // Avoid a CryptoKit dependency — CommonCrypto is always available.
        var hash = [UInt8](repeating: 0, count: 32)
        let data = Array(s.utf8)
        commonCryptoSHA256(data, into: &hash)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Errors

public enum BithumanAuthError: Error, CustomStringConvertible, Sendable {

    /// Account balance dropped below the minimum threshold during
    /// streaming. The SDK rejects further `pushAudio` calls until a
    /// new `Bithuman.create(...)` is constructed (after topping up
    /// the account).
    case insufficientBalance(message: String)

    /// Account was suspended by bitHuman support / billing. The SDK
    /// treats this identically to insufficient balance — the session
    /// cannot continue.
    case accountSuspended(message: String)

    /// Runtime-tokens endpoint returned an unexpected status. The
    /// session keeps running on transient errors; repeated consecutive
    /// failures escalate this case to a fatal billing error.
    case unexpectedStatus(code: Int, body: String)

    /// Network layer failed (timeout, DNS, TLS) repeatedly beyond the
    /// tolerance window.
    case networkFailure(underlying: Error)

    /// The JSON body couldn't be parsed as the expected envelope.
    case invalidResponseShape(body: String)

    public var description: String {
        switch self {
        case .insufficientBalance(let m): return "bitHuman billing: insufficient balance — \(m)"
        case .accountSuspended(let m):    return "bitHuman billing: account suspended — \(m)"
        case .unexpectedStatus(let c, let b): return "bitHuman billing: HTTP \(c) — \(b.prefix(200))"
        case .networkFailure(let e):      return "bitHuman billing: network error — \(e.localizedDescription)"
        case .invalidResponseShape(let b): return "bitHuman billing: bad response shape — \(b.prefix(200))"
        }
    }
}

// MARK: - Client

/// Heartbeat task. One instance per `Bithuman` runtime. Starts on
/// `resume()`, stops on `stop()`, terminates the session by setting
/// `fatal` on 402/403.
///
/// The client is the SOURCE OF TRUTH for whether a session is
/// billing-authorized. `Bithuman.pushAudio` consults `fatalError`
/// before accepting new audio; once fatal is set, all subsequent
/// pushes throw until the caller constructs a fresh session.
public actor BithumanHeartbeat {

    public let config: BithumanAuthConfig

    private var task: Task<Void, Never>?
    private var _fatal: BithumanAuthError?

    /// Session-unique transaction ID. Rotates every successful
    /// heartbeat to mirror the Python SDK pattern — the auth-service
    /// deduplicates activity records within a session by looking
    /// back a short window, so per-heartbeat transaction IDs don't
    /// produce runaway activity counts.
    private var transactionID: String = UUID().uuidString

    private let urlSession: URLSession

    /// Wall-clock timestamp of the most recent successful heartbeat.
    /// Used to enforce the offline grace period — if the SDK can't
    /// reach the billing endpoint for `offlineGraceSeconds`
    /// continuously, the session escalates to fatal so the customer
    /// isn't running unmetered indefinitely.
    private var lastSuccessfulHeartbeat: Date

    /// How long the SDK keeps running after the last successful
    /// heartbeat before declaring the session unauthorized. 5 minutes
    /// covers transient connectivity hiccups (subway tunnels, AP
    /// roaming) without letting an offline device run forever.
    public static let offlineGraceSeconds: TimeInterval = 300

    public init(
        config: BithumanAuthConfig,
        urlSession: URLSession = .shared
    ) {
        self.config = config
        self.urlSession = urlSession
        self.lastSuccessfulHeartbeat = Date()
    }

    /// Fatal billing error set by a 402 / 403 response. Nil while
    /// billing is healthy.
    public var fatalError: BithumanAuthError? { _fatal }

    /// Fire the first heartbeat synchronously so callers know
    /// authentication is valid before any audio is pushed. Throws on
    /// immediate billing failure.
    public func authenticate() async throws {
        try await performHeartbeat()
    }

    /// Start the periodic heartbeat loop. Idempotent.
    public func resume() {
        guard task == nil else { return }
        let interval = config.interval
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { break }
                await self?.tick()
                if self == nil { break }
            }
        }
    }

    /// Cancel the heartbeat loop. Safe to call multiple times.
    public func stop() {
        task?.cancel()
        task = nil
    }

    // MARK: - Internals

    private func tick() async {
        // If we've already terminated the session, stop firing.
        if _fatal != nil {
            stop()
            return
        }
        do {
            try await performHeartbeat()
        } catch let err as BithumanAuthError {
            switch err {
            case .insufficientBalance, .accountSuspended:
                _fatal = err
                stop()
            default:
                // Non-fatal in isolation — but if the network has
                // been down longer than the grace window, escalate.
                escalateIfOfflineTooLong(carrying: err)
                return
            }
        } catch {
            // Unclassified — wrap as networkFailure for the grace
            // calculation, then retry on the next scheduled tick.
            escalateIfOfflineTooLong(
                carrying: .networkFailure(underlying: error)
            )
            return
        }
    }

    /// Escalate a non-billing error to fatal IF we've been offline
    /// past the grace window. Callers handle the non-fatal-but-still-
    /// continue case themselves (just `return`-ing from `tick`).
    private func escalateIfOfflineTooLong(carrying err: BithumanAuthError) {
        let elapsed = Date().timeIntervalSince(lastSuccessfulHeartbeat)
        if elapsed > Self.offlineGraceSeconds {
            _fatal = err
            stop()
        }
    }

    private func performHeartbeat() async throws {
        var req = URLRequest(url: config.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(config.apiSecret,   forHTTPHeaderField: "api-secret")

        let body: [String: Any] = [
            "fingerprint":    config.fingerprint,
            "transaction_id": transactionID,
            "billing_type":   config.billingType,
            "tags":           config.tags,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 30

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: req)
        } catch {
            throw BithumanAuthError.networkFailure(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw BithumanAuthError.invalidResponseShape(
                body: String(data: data, encoding: .utf8) ?? "")
        }

        let bodyText = String(data: data, encoding: .utf8) ?? ""

        switch http.statusCode {
        case 200:
            // Rotate transaction ID on successful heartbeat so the
            // next cycle counts as incremental billing, mirroring the
            // Python runtime. Stamp the success time too — the
            // offline-grace logic in tick() reads this.
            transactionID = UUID().uuidString
            lastSuccessfulHeartbeat = Date()
            return

        case 402:
            throw BithumanAuthError.insufficientBalance(message: extractMessage(bodyText))

        case 403:
            throw BithumanAuthError.accountSuspended(message: extractMessage(bodyText))

        default:
            throw BithumanAuthError.unexpectedStatus(code: http.statusCode, body: bodyText)
        }
    }

    private func extractMessage(_ body: String) -> String {
        // Best-effort pull of `message` from the JSON envelope.
        guard let data = body.data(using: .utf8),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg  = obj["message"] as? String
        else { return body.isEmpty ? "no body" : body }
        return msg
    }
}


// MARK: - CommonCrypto shim

// Pulled out of the config struct to keep the main module header
// short. `CC_SHA256` is in CommonCrypto which links automatically
// via `import Foundation` on Darwin.
import CommonCrypto

private func commonCryptoSHA256(_ bytes: [UInt8], into out: inout [UInt8]) {
    bytes.withUnsafeBufferPointer { buf in
        _ = CC_SHA256(buf.baseAddress, CC_LONG(buf.count), &out)
    }
}
