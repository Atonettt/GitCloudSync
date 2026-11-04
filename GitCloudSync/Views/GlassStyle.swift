import SwiftUI

/// The app's look: native controls on frosted-glass panels over a soft colour wash.

/// Soft, static colour wash behind the glass panels, echoing the blue and purple of the icon.
struct GlassBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let strength = scheme == .dark ? 0.30 : 0.20
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                blob(Color(red: 0.31, green: 0.49, blue: 1.00), strength, size: max(w, h) * 0.65)
                    .position(x: w * 0.10, y: h * 0.05)
                blob(Color(red: 0.56, green: 0.37, blue: 0.97), strength, size: max(w, h) * 0.55)
                    .position(x: w * 0.95, y: h * 0.30)
                blob(Color(red: 0.20, green: 0.74, blue: 0.95), strength * 0.8, size: max(w, h) * 0.55)
                    .position(x: w * 0.35, y: h * 1.00)
            }
            .drawingGroup()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func blob(_ color: Color, _ opacity: Double, size: CGFloat) -> some View {
        Circle()
            .fill(color.opacity(opacity))
            .frame(width: size, height: size)
            .blur(radius: size * 0.28)
    }
}

/// The one panel style used everywhere (control bar, cards, history columns), so they all look alike:
/// Liquid Glass on macOS 26, and before that a frosted panel with an edge highlight and soft shadow.
struct GlassPanel: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var cornerRadius: CGFloat = 16
    /// Outlines the panel in a status colour (for example red when a repository has a problem).
    var tint: Color?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
                .overlay {
                    if let tint { shape.strokeBorder(tint.opacity(0.55), lineWidth: 1.5) }
                }
        } else {
            frosted(content, shape: shape)
        }
    }

    private func frosted(_ content: Content, shape: RoundedRectangle) -> some View {
        content
            .background(.regularMaterial, in: shape)
            .overlay(shape.strokeBorder(highlight, lineWidth: 1))
            .overlay {
                if let tint { shape.strokeBorder(tint.opacity(0.55), lineWidth: 1.5) }
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.07), radius: 14, x: 0, y: 6)
    }

    private var highlight: LinearGradient {
        LinearGradient(
            colors: [.white.opacity(scheme == .dark ? 0.16 : 0.80), .white.opacity(scheme == .dark ? 0.03 : 0.20)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = 16, tint: Color? = nil) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius, tint: tint))
    }
}

/// A subtle inset area inside a glass panel.
struct InsetBackground: ViewModifier {
    var cornerRadius: CGFloat = 10

    func body(content: Content) -> some View {
        content.background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension View {
    func insetBackground(cornerRadius: CGFloat = 10) -> some View {
        modifier(InsetBackground(cornerRadius: cornerRadius))
    }
}
