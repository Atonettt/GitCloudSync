import SwiftUI

extension SyncStatus {
    var color: Color {
        switch self {
        case .notSynced: .secondary
        case .pending, .checking: .blue
        case .downloading, .uploading: .accentColor
        case .success, .noChanges: .green
        case .failed: .red
        case .needsAuth: .orange
        case .conflict: .orange
        case .networkUnavailable: .gray
        }
    }

    var symbol: String {
        switch self {
        case .notSynced: "circle.dashed"
        case .pending: "clock"
        case .checking: "magnifyingglass"
        case .downloading: "arrow.down.circle"
        case .uploading: "arrow.up.circle"
        case .success: "checkmark.circle.fill"
        case .noChanges: "checkmark.circle"
        case .failed: "xmark.octagon.fill"
        case .needsAuth: "person.badge.key.fill"
        case .conflict: "exclamationmark.triangle.fill"
        case .networkUnavailable: "wifi.slash"
        }
    }
}

extension LogLevel {
    var color: Color {
        switch self {
        case .info: .secondary
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }

    var symbol: String {
        switch self {
        case .info: "info.circle"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }
}

struct StatusBadge: View {
    let status: SyncStatus

    var body: some View {
        HStack(spacing: 4) {
            if status.isActive {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: status.symbol)
            }
            Text(status.displayName)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(status.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(status.color.opacity(0.12), in: Capsule())
    }
}

/// The app's own icon (from the bundle), so in-app branding always matches the Dock and Finder.
struct AppIconView: View {
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension Date {
    var relativeDescription: String {
        let seconds = Date().timeIntervalSince(self)
        if seconds < 60 { return String(localized: "刚刚") }
        return formatted(.relative(presentation: .named))
    }
}
