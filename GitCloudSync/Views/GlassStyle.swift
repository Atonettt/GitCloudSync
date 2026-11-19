import SwiftUI

/// The app's look: native controls on glass panels over a see-through frosted window.

/// See-through frosted window background: the desktop and windows behind GitSync show through,
/// blurred, like Finder's sidebar but lighter. The window itself is made non-opaque and the blur
/// layer only partly covers it, so more of what is behind comes through.
struct GlassBackdrop: View {
    var body: some View {
        // Fully covered by the blur: still frosted, but no unblurred text from windows behind bleeds through.
        BehindWindowBlur(opacity: 1.0)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

/// AppKit's behind-window blur (NSVisualEffectView), always active so the window stays frosted
/// even when it is not the front window.
struct BehindWindowBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    /// Below 1 the window's own background must be clear, otherwise it shows grey through the gaps.
    var opacity: CGFloat = 1

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = SeeThroughEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = material
        view.alphaValue = opacity
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.alphaValue = opacity
    }

    private final class SeeThroughEffectView: NSVisualEffectView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard alphaValue < 1, let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
        }
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

/// Capsule glass buttons for the toolbar-like rows: Liquid Glass on macOS 26, bordered before.
struct GlassButtonModifier: ViewModifier {
    var prominent = false

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                // The filled glass style barely changes under the pointer; lighten it like the others.
                content.buttonStyle(.glassProminent).hoverBrighten()
            } else {
                content.buttonStyle(.glass)
            }
        } else if prominent {
            content.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).hoverBrighten()
        } else {
            content.buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
    }
}

extension View {
    func glassButton(prominent: Bool = false) -> some View {
        modifier(GlassButtonModifier(prominent: prominent))
    }
}

/// Lets the frosted window show through the title bar too, instead of a solid toolbar strip.
struct TransparentToolbar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content
        }
    }
}

/// Hover feedback for buttons whose native style has none (borderless, plain, link, bordered and
/// prominent buttons on macOS), so every button reacts to the pointer like the glass ones do.
struct HoverHighlight: ViewModifier {
    enum Kind {
        /// A soft rounded wash behind the button, for buttons without a background of their own.
        case wash
        /// Lightens a button that already has a filled background.
        case brighten
        /// A light layer laid over a system control (segmented switch, pop-up menu). Changing the
        /// control's own brightness makes AppKit redraw it, which flickers; an overlay doesn't touch it.
        case overlay
    }

    var kind: Kind
    var cornerRadius: CGFloat = 6
    /// How far the wash reaches past the button's own frame.
    var inset: CGFloat = 4
    /// Separate reach sideways and up/down, for list rows whose padding differs by direction.
    var horizontalInset: CGFloat?
    var verticalInset: CGFloat?

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        let active = hovering && isEnabled
        Group {
            switch kind {
            case .wash:
                content.background {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.primary.opacity(active ? 0.10 : 0))
                        .padding(.horizontal, -(horizontalInset ?? inset))
                        .padding(.vertical, -(verticalInset ?? inset))
                        .allowsHitTesting(false)
                }
            case .brighten:
                content.brightness(active ? 0.08 : 0)
            case .overlay:
                content.overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.white.opacity(active ? 0.07 : 0))
                        .allowsHitTesting(false)
                }
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: active)
    }
}

extension View {
    /// A rounded wash behind a borderless, plain or link button while the pointer is over it.
    func hoverHighlight(cornerRadius: CGFloat = 6, inset: CGFloat = 4) -> some View {
        modifier(HoverHighlight(kind: .wash, cornerRadius: cornerRadius, inset: inset))
    }

    /// A wash filling a list row (the same area as its selection) while the pointer is over it.
    func hoverRow() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())   // the whole row, not just its text, reacts
            .modifier(HoverHighlight(kind: .wash, cornerRadius: 7, horizontalInset: 8, verticalInset: 3))
    }

    /// Hover feedback for a segmented switch or pop-up menu, without redrawing the control itself.
    func hoverControl(cornerRadius: CGFloat = 7) -> some View {
        modifier(HoverHighlight(kind: .overlay, cornerRadius: cornerRadius))
    }

    /// Lightens a bordered or prominent button while the pointer is over it.
    func hoverBrighten() -> some View {
        modifier(HoverHighlight(kind: .brighten))
    }
}
