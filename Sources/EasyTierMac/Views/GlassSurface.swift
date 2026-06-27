import SwiftUI

/// 统一的磨砂玻璃表面原语。
///
/// 所有玻璃容器（卡片、面板、输入框、横幅、sheet 背景）都应通过
/// `glassSurface(_:tint:)` 落地，避免在各 View 里手写
/// `RoundedRectangle + .thinMaterial + strokeBorder + shadow`。
///
/// 设计目标：
/// 1. 整张界面所有玻璃容器圆角 / 边框 / 阴影 / 高光一致；
/// 2. 顶部镜面高光，提供“反射”感；
/// 3. macOS 26+ 走真 Liquid Glass（`glassEffect`）；旧系统退化到
///    `.thinMaterial` + 手绘顶部高光；
/// 4. 启用「减少透明度」辅助功能时，退化成纯色填充，仍保留高光与边框。
enum GlassTier {
    /// 输入框 / tag / 小型 inline 容器
    case field
    /// 卡片 / metric / banner
    case card
    /// 大型面板 / chart container / sheet section
    case panel

    var cornerRadius: CGFloat {
        switch self {
        case .field: return 6
        case .card: return 8
        case .panel: return 10
        }
    }

    var shadowRadius: CGFloat {
        switch self {
        case .field: return 0
        case .card: return 4
        case .panel: return 10
        }
    }

    var shadowY: CGFloat {
        switch self {
        case .field: return 0
        case .card: return 2
        case .panel: return 5
        }
    }
}

/// 玻璃容器的浅染色。统一代替散落在各处的 `Color.xxx.opacity(0.08)` 灰底。
enum GlassTint: Equatable {
    case neutral
    case accent
    case success
    case danger
    case warning

    var color: Color? {
        switch self {
        case .neutral: return nil
        case .accent: return .accentColor
        case .success: return Color(red: 0.35, green: 0.78, blue: 0.42)
        case .danger: return .red
        case .warning: return .orange
        }
    }

    /// 旧路径下叠在 `.thinMaterial` 之上的染色不透明度。
    var legacyTintOpacity: Double { 0.10 }
}

// MARK: - Modifier

private struct GlassSurfaceModifier: ViewModifier {
    let tier: GlassTier
    let tint: GlassTint
    let isSelected: Bool
    let isInteractive: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: tier.cornerRadius, style: .continuous)

        if reduceTransparency {
            content
                .background(solidBackground(in: shape))
                .overlay(legacyHighlight(in: shape))
                .overlay(borderOverlay(in: shape))
                .shadow(color: shadowColor, radius: tier.shadowRadius, y: tier.shadowY)
        } else if #available(macOS 26.0, *) {
            let _ = { once(&Self._glassLiquidLogged) {
                print("[GlassSurface] ✅ Liquid Glass active (glassEffect)")
            } }()
            content
                .background(
                    shape
                        .fill(.clear)
                        .glassEffect(liquidGlassStyle, in: shape)
                )
                .overlay(borderOverlay(in: shape))
                .shadow(color: shadowColor, radius: tier.shadowRadius, y: tier.shadowY)
        } else {
            let _ = { once(&Self._glassLegacyLogged) {
                print("[GlassSurface] ⬇️ Legacy mode (.thinMaterial + highlight)")
            } }()
            content
                .background(legacyMaterialBackground(in: shape))
                .overlay(legacyHighlight(in: shape))
                .overlay(borderOverlay(in: shape))
                .shadow(color: shadowColor, radius: tier.shadowRadius, y: tier.shadowY)
        }
    }

    nonisolated(unsafe) private static var _glassLiquidLogged = false
    nonisolated(unsafe) private static var _glassLegacyLogged = false

/// Execute block exactly once — one-shot print helper.
private func once(_ flag: inout Bool, _ block: () -> Void) {
    guard !flag else { return }
    flag = true
    block()
}

    // MARK: macOS 26+ (Liquid Glass)

    @available(macOS 26.0, *)
    private var liquidGlassStyle: Glass {
        var style: Glass = .regular
        if isInteractive { style = style.interactive() }
        if let tintColor = tint.color { style = style.tint(tintColor) }
        return style
    }

    // MARK: Legacy (macOS 14 / 15)

    private func legacyMaterialBackground<S: InsettableShape>(in shape: S) -> some View {
        tintedFill
            .background(.thinMaterial, in: shape)
    }

    private var tintedFill: Color {
        guard let c = tint.color else { return .clear }
        return c.opacity(tint.legacyTintOpacity)
    }

    // 顶部 1.5pt 镜面高光 —— 反射感的核心来源（旧系统手绘）
    @ViewBuilder
    private func legacyHighlight<S: InsettableShape>(in shape: S) -> some View {
        LinearGradient(
            colors: [
                .white.opacity(highlightOpacity),
                .white.opacity(highlightOpacity * 0.35),
                .clear
            ],
            startPoint: .top,
            endPoint: .center
        )
        .clipShape(shape)
        .allowsHitTesting(false)
    }

    // reduceTransparency 兜底：实色
    private func solidBackground<S: InsettableShape>(in shape: S) -> some View {
        Color(nsColor: .windowBackgroundColor)
            .opacity(colorScheme == .dark ? 0.72 : 0.86)
            .overlay(tintedFill)
            .clipShape(shape)
    }

    private var highlightOpacity: Double {
        switch tier {
        case .field: return isInteractive ? 0.24 : 0.16
        case .card: return isSelected ? 0.30 : 0.18
        case .panel: return 0.14
        }
    }

    // 玻璃边缘 0.5pt 描边。26+ 也保留一道浅描边以强化"被光照射的玻璃边"
    @ViewBuilder
    private func borderOverlay<S: InsettableShape>(in shape: S) -> some View {
        if isSelected {
            shape.strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
        } else {
            shape.strokeBorder(.white.opacity(borderOpacity), lineWidth: 0.5)
        }
    }

    private var borderOpacity: Double {
        colorScheme == .dark ? 0.10 : 0.18
    }

    private var shadowColor: Color {
        colorScheme == .dark ? .black.opacity(0.24) : .black.opacity(0.06)
    }
}

extension View {
    /// 统一的玻璃表面修饰符。
    ///
    /// - Parameters:
    ///   - tier: 容器尺寸档位，决定圆角 / 阴影 / 高光强度。
    ///   - tint: 可选浅染色（accent / success / danger / warning），
    ///     代替手写的 `Color.xxx.opacity(0.08)` 灰底。
    ///   - isSelected: 选中态会将边框换成 accent 描边，高光增强。
    ///   - isInteractive: 输入框等可交互容器使用更强顶部高光，
    ///     并在 macOS 26+ 启用 `.interactive()`。
    func glassSurface(
        _ tier: GlassTier,
        tint: GlassTint = .neutral,
        isSelected: Bool = false,
        isInteractive: Bool = false
    ) -> some View {
        modifier(
            GlassSurfaceModifier(
                tier: tier,
                tint: tint,
                isSelected: isSelected,
                isInteractive: isInteractive
            )
        )
    }

    /// sheet 弹层的统一背景。26+ 用 Liquid Glass，否则 `.thinMaterial`。
    @ViewBuilder
    func glassPresentationBackground() -> some View {
        if #available(macOS 26.0, *) {
            self.presentationBackground {
                Rectangle()
                    .fill(.clear)
                    .glassEffect(.regular, in: Rectangle())
            }
        } else {
            self.presentationBackground(.thinMaterial)
        }
    }
}