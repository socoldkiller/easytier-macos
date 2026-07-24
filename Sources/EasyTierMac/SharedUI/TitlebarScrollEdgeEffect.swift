import SwiftUI

extension View {
    @ViewBuilder
    func easyTierTitlebarScrollEdgeStyle(isEnabled: Bool) -> some View {
        if isEnabled {
            if #available(macOS 26.0, *) {
                scrollClipDisabled()
                    .scrollEdgeEffectStyle(.hard, for: .top)
            } else {
                scrollClipDisabled()
            }
        } else {
            if #available(macOS 26.0, *) {
                scrollEdgeEffectHidden(true, for: .top)
            } else {
                self
            }
        }
    }

    @ViewBuilder
    func easyTierTitlebarScrollEdgeBackground(
        isVisible: Bool,
        glassEffectsEnabled: Bool
    ) -> some View {
        if glassEffectsEnabled {
            toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .background {
                    TitlebarScrollEdgeEffectBridge(isVisible: isVisible)
                        .frame(width: 0, height: 0)
                }
        } else {
            toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
    }
}
