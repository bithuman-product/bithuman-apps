// LiveKitTokenGenerator.swift
//
// Mints LiveKit access-token JWTs (HS256) for the three identities
// that share a room while `bithuman-cli serve` is running:
//
//   - "user"   browser tab          publishes mic, subscribes to bot audio + avatar video
//   - "brain"  Swift bridge         subscribes to user mic, publishes bot audio
//   - "avatar" essence-server       subscribes to brain audio, publishes avatar video
//
// Tokens are signed with the API secret the local `livekit-server`
// dev instance was started with — both API key + secret are random
// and live only for the lifetime of `bithuman-cli serve`.
//
// LiveKit token spec: https://docs.livekit.io/realtime/concepts/authentication/

import Foundation
import JWTKit

/// Generator for LiveKit access-token JWTs.
public struct LiveKitTokenGenerator: Sendable {
    public let apiKey: String        // matches livekit-server's --keys flag
    public let apiSecret: String     // matches livekit-server's --keys flag
    public let roomName: String      // shared by all three identities

    public init(apiKey: String, apiSecret: String, roomName: String) {
        self.apiKey = apiKey
        self.apiSecret = apiSecret
        self.roomName = roomName
    }

    /// One-shot mint — TTL defaults to 6 hours, identity is the
    /// participant name, grants are scoped to the configured room.
    public func mintToken(
        identity: String,
        canPublish: Bool,
        canSubscribe: Bool,
        canPublishData: Bool = true,
        ttl: TimeInterval = 21_600
    ) async throws -> String {
        let now = Date()
        let payload = LiveKitAccessTokenPayload(
            iss: IssuerClaim(value: apiKey),
            sub: SubjectClaim(value: identity),
            nbf: NotBeforeClaim(value: now),
            exp: ExpirationClaim(value: now.addingTimeInterval(ttl)),
            name: identity,
            video: VideoGrant(
                room: roomName,
                roomJoin: true,
                canPublish: canPublish,
                canSubscribe: canSubscribe,
                canPublishData: canPublishData
            )
        )

        let keys = JWTKeyCollection()
        await keys.add(hmac: HMACKey(stringLiteral: apiSecret), digestAlgorithm: .sha256)
        return try await keys.sign(payload)
    }

    /// Convenience: random API key + secret pair suitable for
    /// passing to `livekit-server --keys` and to this generator.
    /// Cryptographically random; never persisted to disk.
    ///
    /// - API key: `APIKey` + 16 hex chars (matches LiveKit's CLI tool format).
    /// - Secret: 32 random bytes, base64-encoded (>=43 chars after base64).
    public static func randomDevCredentials() -> (apiKey: String, apiSecret: String) {
        var rng = SystemRandomNumberGenerator()

        // 8 random bytes -> 16 hex chars.
        var keyBytes = [UInt8](repeating: 0, count: 8)
        for i in 0..<keyBytes.count {
            keyBytes[i] = UInt8.random(in: 0...UInt8.max, using: &rng)
        }
        let hex = keyBytes.map { String(format: "%02x", $0) }.joined()
        let apiKey = "APIKey" + hex

        // 32 random bytes -> base64 (44 chars including '=' padding).
        var secretBytes = [UInt8](repeating: 0, count: 32)
        for i in 0..<secretBytes.count {
            secretBytes[i] = UInt8.random(in: 0...UInt8.max, using: &rng)
        }
        let apiSecret = Data(secretBytes).base64EncodedString()

        return (apiKey, apiSecret)
    }
}

// MARK: - JWT payload

/// Custom JWTPayload matching the LiveKit access-token claim schema.
///
/// Standard claims:
///   iss   apiKey
///   sub   identity
///   nbf   now
///   exp   now + ttl
///   name  identity (echoed)
/// Custom claim:
///   video { room, roomJoin, canPublish, canSubscribe, canPublishData }
private struct LiveKitAccessTokenPayload: JWTPayload {
    var iss: IssuerClaim
    var sub: SubjectClaim
    var nbf: NotBeforeClaim
    var exp: ExpirationClaim
    var name: String
    var video: VideoGrant

    func verify(using algorithm: some JWTAlgorithm) throws {
        // Issuance side only — we never verify our own minted tokens.
        try exp.verifyNotExpired()
    }
}

private struct VideoGrant: Codable, Sendable {
    var room: String
    var roomJoin: Bool
    var canPublish: Bool
    var canSubscribe: Bool
    var canPublishData: Bool
}

#if DEBUG
// Compile-time smoke: instantiate the type to make sure the API
// surface lines up. Never actually called.
private let _liveKitTokenGeneratorSmoke: @Sendable () -> Void = {
    let (k, s) = LiveKitTokenGenerator.randomDevCredentials()
    _ = LiveKitTokenGenerator(apiKey: k, apiSecret: s, roomName: "x")
}
#endif
