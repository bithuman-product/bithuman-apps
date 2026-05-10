// SPDX-License-Identifier: Apache-2.0
//
// ServeRunner — orchestrates `bithuman-cli serve`.
//
// Spawns the four moving pieces of a local "production-shape" stack:
//
//   1. livekit-server         dev mode at ws://127.0.0.1:<livekit-port>
//                             Subprocess; the Homebrew `livekit` formula
//                             provides the binary.
//   2. essence-server         joins the room as `avatar`; subscribes to
//                             brain audio and publishes lip-synced video.
//                             Subprocess from bithuman-sdk's swift build.
//   3. BithumanLiveKitBridge  joins the room as `brain`; subscribes to
//                             user mic audio, peers to OpenAI Realtime,
//                             publishes bot audio. In-process.
//   4. Hummingbird HTTP       :8090. Serves the static web client at /;
//                             the HTML is template-substituted at fetch
//                             time so each page load gets its own
//                             "user" identity JWT.
//
// Lifecycle: the run() entry awaits all four are healthy, then blocks
// until SIGINT / SIGTERM. Cleanup tears down in reverse order.

#if canImport(Hummingbird)
import Foundation
import Hummingbird
import bitHumanKit
import BithumanLiveKitBridge

/// CLI-side spec parsed from `bithuman-cli serve --…` flags.
struct ServeArgs {
    var port: Int = 8090
    var livekitPort: Int = 7880
    var openaiModel: String = "gpt-realtime-mini"
    var openaiVoice: String = DefaultEssenceAgent.realtimeVoice  // "ballad"
    var identityPath: String? = nil
    var promptOverride: String? = nil
    var openBrowser: Bool = true
}

/// Top-level entry. Resolves keys, runs preflight, sets up the
/// subprocesses + bridge + HTTP server, blocks until interrupted.
@MainActor
func runServeMode(args: ServeArgs) async throws {
    // 1. Preflight — credentials + binaries + ports.
    guard let openaiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
        ?? BithumanKeychain.loadOpenAIKey()
    else {
        fatalKey()
    }
    guard BithumanKey.load() != nil else {
        fatalBitHumanKeyMissing()
    }
    guard let identity = args.identityPath else {
        fatalUsage("`serve` requires --identity <agent.imx>. Pick one from your bitHuman dashboard at https://www.bithuman.ai")
    }
    let identityURL = URL(fileURLWithPath: (identity as NSString).expandingTildeInPath)
    guard FileManager.default.fileExists(atPath: identityURL.path) else {
        fatalUsage("--identity: file not found at '\(identityURL.path)'")
    }
    guard let livekitBin = ServePreflight.locateLiveKitServer() else {
        FileHandle.standardError.write(Data((ServePreflight.liveKitServerInstallHint + "\n").utf8))
        exit(2)
    }
    guard let essenceBin = ServePreflight.locateEssenceServer() else {
        FileHandle.standardError.write(Data("""
            error: essence-server binary not found. It's part of the bitHuman SDK build:

                git clone https://github.com/bithuman-product/bithuman-sdk
                cd bithuman-sdk/swift
                swift build -c release --product essence-server

            Then re-run `bithuman-cli serve`.

            """.utf8))
        exit(2)
    }
    guard ServePreflight.portIsFree(args.port) else {
        fatalUsage("port \(args.port) is in use — pass --port <N> to pick a different one.")
    }
    guard ServePreflight.portIsFree(args.livekitPort) else {
        fatalUsage("port \(args.livekitPort) is in use — pass --livekit-port <N> to pick a different one for livekit-server.")
    }

    // 2. Mint dev credentials + JWTs for the three identities.
    let (apiKey, apiSecret) = LiveKitTokenGenerator.randomDevCredentials()
    let roomName = "bithuman-cli-serve-\(UUID().uuidString.prefix(8))"
    let tokens = LiveKitTokenGenerator(apiKey: apiKey, apiSecret: apiSecret, roomName: roomName)
    let userToken   = try await tokens.mintToken(identity: "user",   canPublish: true,  canSubscribe: true)
    let brainToken  = try await tokens.mintToken(identity: "brain",  canPublish: true,  canSubscribe: true)
    let avatarToken = try await tokens.mintToken(identity: "avatar", canPublish: true,  canSubscribe: true)
    let livekitWSURL = "ws://127.0.0.1:\(args.livekitPort)"

    print("\n  bithuman-cli serve")
    print("    livekit room:  \(roomName)")
    print("    livekit url:   \(livekitWSURL)")
    print("    web client:    http://127.0.0.1:\(args.port)")
    print("    avatar imx:    \(identityURL.lastPathComponent)\n")

    // 3. Spawn livekit-server (dev mode, our minted creds).
    let livekit = SubprocessHandle(
        binary: livekitBin,
        args: [
            "--dev",
            "--bind", "127.0.0.1",
            "--port", "\(args.livekitPort)",
            "--keys", "\(apiKey): \(apiSecret)",
        ],
        label: "livekit-server",
        // Drop livekit-server's per-RTC-event DEBUG logs by default —
        // they dominate stderr during serve. Re-enable via env when
        // diagnosing transport bugs.
        suppressIfMatches: [
            "DEBUG\tlivekit",
            "INFO\tlivekit\trouting/",
            "INFO\tlivekit\tservice/",
        ]
    )
    try livekit.start()

    // Give livekit-server ~2s to come up before bridge / essence-server
    // try to dial it. (Faster polling possible via TCP probe.)
    try await waitForPortOpen(host: "127.0.0.1", port: args.livekitPort, timeout: 5.0)

    // 4. Spawn essence-server, then POST /launch to wire it into the room.
    // Pick a free ephemeral-range port so we don't collide with VS Code
    // helpers / dev tools commonly squatting on 8000-8100.
    var essencePort = 18089
    while !ServePreflight.portIsFree(essencePort) && essencePort < 18120 {
        essencePort += 1
    }
    guard ServePreflight.portIsFree(essencePort) else {
        fatalUsage("couldn't find a free port for essence-server in 18089-18120 range")
    }
    let essence = SubprocessHandle(
        binary: essenceBin,
        args: [
            "--port", "\(essencePort)",
            "--host", "127.0.0.1",
        ],
        label: "essence-server"
    )
    try essence.start()
    try await waitForPortOpen(host: "127.0.0.1", port: essencePort, timeout: 10.0)
    try await essenceServerLaunch(
        port: essencePort,
        livekitURL: livekitWSURL,
        livekitToken: avatarToken,
        roomName: roomName,
        modelPath: identityURL
    )

    // 5. Start the in-process bridge.
    let bridgeConfig = BithumanLiveKitBridge.Config(
        livekitURL: URL(string: livekitWSURL)!,
        livekitToken: brainToken,
        openaiAPIKey: openaiKey,
        openaiModel: args.openaiModel,
        voice: args.openaiVoice,
        instructions: args.promptOverride ?? DefaultEssenceAgent.systemPrompt
    )
    let bridge = BithumanLiveKitBridge(config: bridgeConfig)
    try await bridge.start()

    // Surface bridge events as a status pulse on stderr.
    let bridgeEventsTask = Task {
        for await event in bridge.events {
            switch event {
            case .bridgeConnected:    FileHandle.standardError.write(Data("✓ bridge connected\n".utf8))
            case .userSpeaking(true):  FileHandle.standardError.write(Data("→ user speaking\n".utf8))
            case .userSpeaking(false): break
            case .botSpeaking(true):   FileHandle.standardError.write(Data("← bot speaking\n".utf8))
            case .botSpeaking(false):  break
            case .error(let m):        FileHandle.standardError.write(Data("⚠ bridge error: \(m)\n".utf8))
            }
        }
    }

    // 6. Hummingbird HTTP server with the static web client.
    let webRoot = bundledWebRootURL()
    let app = try makeWebApp(
        root: webRoot,
        port: args.port,
        livekitURL: livekitWSURL,
        userToken: userToken,
        roomName: roomName
    )

    // 7. Open default browser.
    if args.openBrowser {
        let url = "http://127.0.0.1:\(args.port)"
        _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: [url])
    }

    // 8. SIGINT / SIGTERM trap → orderly cleanup.
    let signalSource = installSignalHandler()
    let appTask = Task { try await app.runService() }

    // Block until signal.
    await signalSource.wait()
    print("\n⏹  shutting down…")

    // Reverse-order cleanup.
    appTask.cancel()
    bridgeEventsTask.cancel()
    await bridge.stop()
    essence.terminate()
    livekit.terminate()
    print("  done.")
}

// MARK: - Hummingbird app

private func makeWebApp(
    root: URL,
    port: Int,
    livekitURL: String,
    userToken: String,
    roomName: String
) throws -> some ApplicationProtocol {
    let router = Router()

    // index.html — template-substitute the three placeholders.
    router.get("/") { request, context -> Response in
        let indexURL = root.appendingPathComponent("index.html")
        var html = try String(contentsOf: indexURL, encoding: .utf8)
        html = html.replacingOccurrences(of: "__LIVEKIT_URL__", with: livekitURL)
        html = html.replacingOccurrences(of: "__LIVEKIT_TOKEN__", with: userToken)
        html = html.replacingOccurrences(of: "__ROOM_NAME__", with: roomName)
        return Response(
            status: .ok,
            headers: [.contentType: "text/html; charset=utf-8"],
            body: ResponseBody(byteBuffer: ByteBuffer(string: html))
        )
    }

    // Static asset passthrough for client.js + style.css. Whitelist
    // only those two filenames so we don't accidentally serve other
    // bundle resources.
    router.get("/client.js") { _, _ -> Response in
        let assetURL = root.appendingPathComponent("client.js")
        let bytes = try Data(contentsOf: assetURL)
        return Response(
            status: .ok,
            headers: [.contentType: "application/javascript; charset=utf-8"],
            body: ResponseBody(byteBuffer: ByteBuffer(bytes: bytes))
        )
    }
    router.get("/style.css") { _, _ -> Response in
        let assetURL = root.appendingPathComponent("style.css")
        let bytes = try Data(contentsOf: assetURL)
        return Response(
            status: .ok,
            headers: [.contentType: "text/css; charset=utf-8"],
            body: ResponseBody(byteBuffer: ByteBuffer(bytes: bytes))
        )
    }

    return Application(
        router: router,
        configuration: .init(address: .hostname("127.0.0.1", port: port))
    )
}

private func bundledWebRootURL() -> URL {
    // Resources are bundled via `Bundle.module` (see Package.swift's
    // `resources:` block on the BithumanCLI target).
    if let url = Bundle.module.url(forResource: "index", withExtension: "html",
                                   subdirectory: "serve-web") {
        return url.deletingLastPathComponent()
    }
    // Dev fallback — running from a swift-build tree before the
    // resources bundle is staged.
    return URL(fileURLWithPath: #file)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Resources/serve-web")
}

// MARK: - essence-server /launch wiring

private func essenceServerLaunch(
    port: Int,
    livekitURL: String,
    livekitToken: String,
    roomName: String,
    modelPath: URL
) async throws {
    let endpoint = URL(string: "http://127.0.0.1:\(port)/launch")!
    var req = URLRequest(url: endpoint)
    req.httpMethod = "POST"
    // essence-server's `parseForm` parses URL-encoded form bodies
    // (`key=value&key=value`), not multipart. Match its expectation.
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
            .replacingOccurrences(of: "&", with: "%26")
            .replacingOccurrences(of: "=", with: "%3D")
            .replacingOccurrences(of: "+", with: "%2B")
            ?? s
    }
    let pairs: [(String, String)] = [
        ("livekit_url", livekitURL),
        ("livekit_token", livekitToken),
        ("room_name", roomName),
        ("avatar_id", "local"),
        ("model_url", "file://\(modelPath.path)"),
    ]
    let body = pairs.map { "\($0.0)=\(enc($0.1))" }.joined(separator: "&")
    req.httpBody = body.data(using: .utf8)
    let (data, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse, http.statusCode / 100 == 2 else {
        let bodyText = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        throw NSError(domain: "ServeRunner", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "essence-server /launch failed with HTTP \(code): \(bodyText)"])
    }
}

// MARK: - subprocess helper

private final class SubprocessHandle: @unchecked Sendable {
    let process: Process
    let label: String
    init(binary: URL, args: [String], label: String, suppressIfMatches: [String] = []) {
        let p = Process()
        p.executableURL = binary
        p.arguments = args
        // Pipe stdout / stderr through this process's stderr with a
        // label prefix so the user can tell who said what.
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        p.standardOutput = stdoutPipe
        p.standardError = stderrPipe
        Self.relay(handle: stdoutPipe.fileHandleForReading, label: "[\(label)]", suppress: suppressIfMatches)
        Self.relay(handle: stderrPipe.fileHandleForReading, label: "[\(label)]", suppress: suppressIfMatches)
        self.process = p
        self.label = label
    }
    func start() throws {
        try process.run()
    }
    func terminate() {
        if process.isRunning {
            process.terminate()
            // Best-effort wait; SIGKILL fallback after 3s.
            let deadline = Date().addingTimeInterval(3.0)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
    private static func relay(handle: FileHandle, label: String, suppress: [String] = []) {
        handle.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty, let raw = String(data: data, encoding: .utf8) else {
                if data.isEmpty { h.readabilityHandler = nil }
                return
            }
            // Filter noisy lines, prefix the rest with the subprocess label.
            let kept = raw.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { line in
                    guard !suppress.isEmpty else { return true }
                    return !suppress.contains { line.contains($0) }
                }
                .map { "\(label) \($0)" }
                .joined(separator: "\n")
            if !kept.isEmpty {
                FileHandle.standardError.write(Data(kept.utf8))
                FileHandle.standardError.write(Data("\n".utf8))
            }
        }
    }
}

// MARK: - signal handling

private func installSignalHandler() -> SignalAwaiter {
    let awaiter = SignalAwaiter()
    let src1 = DispatchSource.makeSignalSource(signal: SIGINT,  queue: .main)
    let src2 = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    src1.setEventHandler { awaiter.fire() }
    src2.setEventHandler { awaiter.fire() }
    src1.resume()
    src2.resume()
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    awaiter.retainSources(src1, src2)
    return awaiter
}

private final class SignalAwaiter: @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Never>?
    private var didFire = false
    private var sources: [Any] = []
    private let lock = NSLock()
    func fire() {
        lock.lock()
        let cont = continuation
        continuation = nil
        didFire = true
        lock.unlock()
        cont?.resume()
    }
    func retainSources(_ s: Any...) { sources.append(contentsOf: s) }
    func wait() async {
        await withCheckedContinuation { cont in
            lock.lock()
            if didFire {
                lock.unlock()
                cont.resume()
            } else {
                continuation = cont
                lock.unlock()
            }
        }
    }
}

// MARK: - port wait helper

private func waitForPortOpen(host: String, port: Int, timeout: TimeInterval) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if !ServePreflight.portIsFree(port) { return }   // someone's listening = ready
        try await Task.sleep(nanoseconds: 200_000_000)
    }
    throw NSError(domain: "ServeRunner", code: 2,
                  userInfo: [NSLocalizedDescriptionKey: "timed out waiting for \(host):\(port) to come up"])
}

#endif  // canImport(Hummingbird)
