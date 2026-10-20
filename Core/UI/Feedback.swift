import SwiftUI
import UIKit

/// Haptics gated by the toggles in Settings.
enum Haptics {
    static func tap() {
        guard AppSettings.shared.hapticsTap else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    static func success() {
        guard AppSettings.shared.hapticsResult else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    static func error() {
        guard AppSettings.shared.hapticsResult else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}

/// Banner messages shown at the top of the screen. Every error path reports here
/// so nothing fails silently.
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    struct Toast: Identifiable, Equatable {
        enum Style { case info, success, error }
        let id = UUID()
        let message: String
        let style: Style
        var actionTitle: String? = nil
        var action: (() -> Void)? = nil
        static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
    }

    /// A message with a button (e.g. Undo). Stays a little longer so there's time to tap it.
    func show(_ message: String, style: Toast.Style = .info, actionTitle: String, action: @escaping () -> Void) {
        DispatchQueue.main.async {
            let t = Toast(message: message, style: style, actionTitle: actionTitle, action: action)
            self.current = t
            self.hideTask?.cancel()
            self.hideTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if !Task.isCancelled, self.current?.id == t.id { self.current = nil }
            }
        }
    }

    @Published var current: Toast?
    private var hideTask: Task<Void, Never>?

    func show(_ message: String, style: Toast.Style = .info) {
        DispatchQueue.main.async {
            self.current = Toast(message: message, style: style)
            switch style {
            case .success: Haptics.success()
            case .error: Haptics.error()
            case .info: break
            }
            self.hideTask?.cancel()
            let id = self.current?.id
            self.hideTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: style == .error ? 5_000_000_000 : 2_500_000_000)
                if !Task.isCancelled, self.current?.id == id { self.current = nil }
            }
        }
    }

    func error(_ error: Error, prefix: String? = nil) {
        if error is CancellationError { return }
        if let u = error as? URLError, u.code == .cancelled { return }
        let msg = error.localizedDescription
        show(prefix.map { "\($0): \(msg)" } ?? msg, style: .error)
    }
}

struct ToastOverlay: View {
    @ObservedObject var center = ToastCenter.shared
    @State private var dragY: CGFloat = 0

    var body: some View {
        VStack {
            if let t = center.current {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(t.style))
                    Text(t.message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if let title = t.actionTitle, let action = t.action {
                        Button(title) { action(); center.current = nil }
                            .font(.subheadline.weight(.bold))
                            .accessibilityIdentifier("toastAction")
                    }
                    Button { center.current = nil } label: { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                        .accessibilityLabel("Dismiss message")
                }
                .foregroundColor(.white)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(color(t.style)))
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .offset(y: min(0, dragY))
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { PassthroughWindow.toastFrame = g.frame(in: .global) }
                        .onChange(of: g.frame(in: .global)) { PassthroughWindow.toastFrame = $0 }
                })
                .onDisappear { PassthroughWindow.toastFrame = nil }
                .transition(.move(edge: .top).combined(with: .opacity))
                // Tapping a plain message closes it; one with a button (Undo, Open) keeps the
                // tap for its button, otherwise this gesture would swallow it.
                .onTapGesture { if t.action == nil { center.current = nil } }
                // Swipe up to dismiss.
                .gesture(DragGesture(minimumDistance: 8)
                    .onChanged { dragY = $0.translation.height }
                    .onEnded { v in
                        if v.translation.height < -30 { center.current = nil }
                        dragY = 0
                    })
                .accessibilityIdentifier("toast")
            }
            Spacer()
        }
        .animation(.spring(), value: center.current)
    }

    func icon(_ s: ToastCenter.Toast.Style) -> String {
        switch s {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    func color(_ s: ToastCenter.Toast.Style) -> Color {
        switch s {
        case .info: return Color.blue.opacity(0.92)
        case .success: return Color.green.opacity(0.92)
        case .error: return Color.red.opacity(0.92)
        }
    }
}
