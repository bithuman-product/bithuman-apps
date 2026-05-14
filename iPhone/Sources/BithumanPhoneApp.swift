//
//  BithumanPhoneApp.swift
//  BithumanPhone — iPhone (compact) variant of the bitHuman avatar app.
//
//  iPhone form factor: full-screen avatar by default, tap to collapse
//  to a 120 pt PiP circle in the bottom-right. Customization opens as
//  sheets with a TabView (Agents / Voice / Prompt) — efficient on a
//  small screen.
//
//  Hardware floor: A18 Pro (iPhone 16 Pro / 17 Pro). Earlier phones
//  thermal-throttle at 25 FPS within ~30 s. The app gates on this at
//  first launch (see HardwareCheck.swift).
//

#if canImport(UIKit)
import SwiftUI
import UIKit
import AVFAudio
import bitHumanKit

@main
struct BithumanPhoneApp: App {
    @UIApplicationDelegateAdaptor(BithumanPhoneAppDelegate.self) private var appDelegate

    @StateObject private var lifecycle = BithumanPhoneLifecycle()

    init() {
        // int4 DiT (~2.6 GB → ~750 MB) and int4 Wav2Vec2 transformer
        // Linears (~190 MB → ~50 MB). Must be set before Bithuman.create
        // reads them in WeightLoader. Overwrite=0 so a launch-env
        // override wins for diagnostics.
        setenv("FH_QUANTIZE_DIT", "int4", 0)
        setenv("FH_QUANTIZE_W2V2", "int4", 0)

        PhoneOrientationLock.lockPortrait()
    }

    var body: some Scene {
        WindowGroup {
            // Hardware gate FIRST. Below A18 Pro the phone thermal-
            // throttles within ~30 s of sustained 25 FPS inference;
            // we'd download 3.7 GB of weights only to refuse to run.
            switch HardwareCheck.evaluate() {
            case .supported:
                iPhoneAvatarRoot(lifecycle: lifecycle)
                    .preferredColorScheme(.dark)
                    .statusBarHidden(true)
                    .persistentSystemOverlays(.hidden)
                    .task {
                        await lifecycle.start()
                    }
                    .onChange(of: lifecycle.shouldKeepScreenAwake) { _, awake in
                        UIApplication.shared.isIdleTimerDisabled = awake
                    }
            case .unsupported(let reason):
                UnsupportedDeviceView(reason: reason)
                    .preferredColorScheme(.dark)
            @unknown default:
                UnsupportedDeviceView(reason: "Unrecognised device capability returned by bitHumanKit. Update the app to a newer release.")
                    .preferredColorScheme(.dark)
            }
        }
    }
}

/// App-delegate. Mirrors the iPad app's delegate but with iPhone-only
/// orientation lock.
final class BithumanPhoneAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        configureAudioSession()
        #if DEBUG
        // Dev builds: keep the screen on the moment the app launches so
        // tethered USB-C testing isn't interrupted by auto-lock during
        // weights download or on the unsupported-device view. Release
        // builds rely on the lifecycle-driven toggle below.
        application.isIdleTimerDisabled = true
        #endif
        return true
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
            )
            try session.setActive(true)
        } catch {
            NSLog("BithumanPhone: audio session config failed: \(error)")
        }
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        .portrait
    }
}

/// iPhone lifecycle. Same shape as `BithumanPadLifecycle` — boots
/// VoiceChat with the avatar engine + default agent, owns the
/// AvatarCoordinator + FramePump + the long-lived UIKit renderer
/// view for the app's lifetime.
@MainActor
final class BithumanPhoneLifecycle: ObservableObject {
    @Published var coordinator: AvatarCoordinator?
    @Published var bootError: String?
    @Published var shouldKeepScreenAwake: Bool = false
    @Published private(set) var rendererView: AvatarRendererView?
    /// First-run download/verify state. Drives the loading UI: ring
    /// with %/speed/ETA when `.downloading`, particle field otherwise.
    @Published private(set) var downloadPhase: DownloadPhase = .verifying

    private var chat: VoiceChat?
    private var framePump: FramePump?

    func start() async {
        guard chat == nil else { return }
        do {
            let weightsURL = try await ExpressionWeights.ensureAvailable { phase in
                Task { @MainActor [weak self] in
                    self?.downloadPhase = phase
                }
            }
            let defaultAgent = AgentCatalog.defaultAgent
            let portraitURL = AgentCatalog.thumbnailURL(for: defaultAgent)

            var config = VoiceChatConfig()
            config.localeIdentifier = "en-US"
            config.systemPrompt = defaultAgent.systemPrompt
            config.avatar = AvatarConfig(modelPath: weightsURL, portraitPath: portraitURL)

            let chat = VoiceChat(config: config)
            self.chat = chat
            try await chat.start()

            guard let bh = chat.bithuman else {
                self.bootError = "Avatar engine failed to initialise."
                return
            }

            await chat.setVoicePreset(defaultAgent.voicePreset)

            let coord = AvatarCoordinator(chat: chat)
            coord.bindToOrchestrator()
            coord.currentSystemPrompt = defaultAgent.systemPrompt
            coord.currentVoicePreset = defaultAgent.voicePreset
            coord.currentAgentCode = defaultAgent.code
            coord.prewarmPortraitURL = portraitURL

            let renderer = AvatarRendererView(frame: .zero, idleFrame: chat.initialIdleFrame)
            let pump = FramePump(bithuman: bh, chat: chat, window: renderer, coordinator: coord)
            coord.framePump = pump
            chat.onBargeIn = { [weak pump] in pump?.buffer.flushSpeech() }
            chat.onCheckSpeechBuffer = { [weak pump] in pump?.buffer.hasSpeech == false }

            self.framePump = pump
            self.rendererView = renderer
            self.coordinator = coord
            self.shouldKeepScreenAwake = true
        } catch {
            self.bootError = "\(error.localizedDescription)"
        }
    }
}

/// iPhone 16 Pro / iOS 26 still honours
/// `UIInterfaceOrientationMask` from the app delegate. With pure
/// SwiftUI lifecycle we additionally set the supported orientations
/// on the connected scene at launch — Info.plist is the authoritative
/// declaration; this catches the rotation-lock-OFF edge case.
enum PhoneOrientationLock {
    static func lockPortrait() {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        else { return }
        let geometry = UIWindowScene.GeometryPreferences.iOS(
            interfaceOrientations: .portrait
        )
        scene.requestGeometryUpdate(geometry) { error in
            print("[BithumanPhone] portrait lock request failed: \(error)")
        }
    }
}
#endif // canImport(UIKit)
