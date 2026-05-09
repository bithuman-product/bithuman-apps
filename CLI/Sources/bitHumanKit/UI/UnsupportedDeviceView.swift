// UnsupportedDeviceView.swift — polite full-screen refusal screen
// for iPad / iPhone hardware below the bitHuman engine's minimum.
//
// Shown by BithumanPadApp / BithumanPhoneApp at first scene appearance
// when `HardwareCheck.evaluate()` returns `.unsupported(reason:)`. The
// engine never gets a chance to load on under-spec hardware; users see
// a clear explanation instead of a crash mid-warm-up.

import SwiftUI

/// Cross-platform SwiftUI view rendered when the device fails the
/// hardware gate. Self-contained — doesn't need a coordinator or
/// any engine state.
public struct UnsupportedDeviceView: View {
    private let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 22) {
                Image(systemName: "iphone.gen3.slash")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.white.opacity(0.85))
                    .symbolRenderingMode(.hierarchical)

                VStack(spacing: 10) {
                    Text("This device isn't supported yet")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)

                    Text(reason)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.72))
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .padding(.horizontal, 28)
                }

                Link("Why these requirements?",
                     destination: URL(string: "https://www.bithuman.ai")!)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(BrandColors.coral)
                    .padding(.top, 4)
            }
            .frame(maxWidth: 460)
            .padding(.horizontal, 28)
        }
    }

    private var backdrop: some View {
        ZStack {
            Color.black
            RadialGradient(
                colors: [
                    BrandColors.coral.opacity(0.18),
                    BrandColors.coral.opacity(0.04),
                    .clear,
                ],
                center: .center,
                startRadius: 60,
                endRadius: 600
            )
            .blur(radius: 40)
        }
        .ignoresSafeArea()
    }
}

#Preview("iPad — unsupported chip") {
    UnsupportedDeviceView(reason:
        "bitHuman needs an iPad Pro M4 or newer. This device (iPad14,1) " +
        "doesn't have the GPU + Neural Engine bandwidth to sustain the " +
        "avatar engine at 25 FPS."
    )
}

#Preview("iPhone — non-Pro") {
    UnsupportedDeviceView(reason:
        "bitHuman needs an A18 Pro chip (iPhone 16 Pro / Pro Max). This " +
        "device (iPhone17,3) is the standard A18 — same RAM, but lacks the " +
        "GPU cores + thermal envelope for sustained 25 FPS."
    )
}
