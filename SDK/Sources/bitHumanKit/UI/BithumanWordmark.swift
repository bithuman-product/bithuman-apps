// BithumanWordmark — small "bitHuman" header shown above loading
// states in iPad / iPhone / Mac. Uses the bundled AppIcon as the
// glyph and a wordmark next to it. Sits at the top of the boot
// screen so the brand reads even before the avatar is on-screen.

import SwiftUI

public struct BithumanWordmark: View {
    private let glyphSide: CGFloat
    private let wordmarkSize: CGFloat

    /// `compact: true` shrinks both the glyph and the type for use
    /// inside the small iPad widget window. Default sizing fits a
    /// full-screen iPhone loading layout.
    public init(compact: Bool = false) {
        if compact {
            self.glyphSide = 36
            self.wordmarkSize = 16
        } else {
            self.glyphSide = 48
            self.wordmarkSize = 22
        }
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image("AppIcon", bundle: .module)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: glyphSide, height: glyphSide)
                .clipShape(RoundedRectangle(cornerRadius: glyphSide * 0.22, style: .continuous))
            Text("bitHuman")
                .font(.system(size: wordmarkSize, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .tracking(0.4)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("bitHuman")
    }
}
