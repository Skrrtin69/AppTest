import SwiftUI

/// Full-screen passcode pad shown while the app is locked.
struct LockScreenView: View {
    @ObservedObject var lock = LockManager.shared
    @ObservedObject var settings = AppSettings.shared
    @State private var entered = ""
    @State private var shake = false
    @State private var message = "Enter Passcode"

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "lock.fill").font(.system(size: 44))
            Text(message).font(.title3.weight(.semibold)).accessibilityIdentifier("lockMessage")
            HStack(spacing: 14) {
                ForEach(0..<6, id: \.self) { i in
                    Circle()
                        .strokeBorder(Color.primary, lineWidth: 1.5)
                        .background(Circle().fill(i < entered.count ? Color.primary : Color.clear))
                        .frame(width: 14, height: 14)
                }
            }
            .offset(x: shake ? 10 : 0)
            PinPad(entered: $entered, onBiometrics: biometricsButton ? { Task { await lock.unlockWithBiometrics() } } : nil,
                   biometryName: lock.biometryName)
            Button("Unlock") { attempt() }
                .buttonStyle(.borderedProminent)
                .disabled(entered.count < 4)
                .accessibilityIdentifier("unlockButton")
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background((settings.theme == .amoled ? Color.black : Color(UIColor.systemBackground)).ignoresSafeArea())
        .onChange(of: entered) { v in
            // Auto-submit at 6 digits; shorter PINs use the Unlock button.
            if v.count == 6 { attempt() }
        }
        .task { await lock.unlockWithBiometrics() }
    }

    var biometricsButton: Bool { settings.biometricsEnabled && lock.biometricsAvailable }

    func attempt() {
        if lock.unlock(with: entered) {
            entered = ""
        } else {
            message = "Wrong passcode — try again"
            entered = ""
            withAnimation(.default.repeatCount(3, autoreverses: true).speed(4)) { shake.toggle() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { shake = false }
        }
    }
}

struct PinPad: View {
    @Binding var entered: String
    var onBiometrics: (() -> Void)?
    var biometryName: String = "Face ID"

    let rows = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]]

    var body: some View {
        VStack(spacing: 14) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 22) { ForEach(row, id: \.self) { key($0) } }
            }
            HStack(spacing: 22) {
                if let bio = onBiometrics {
                    Button(action: bio) {
                        Image(systemName: biometryName == "Touch ID" ? "touchid" : "faceid").font(.title)
                            .frame(width: 72, height: 72)
                    }
                    .accessibilityLabel(biometryName)
                } else {
                    Color.clear.frame(width: 72, height: 72)
                }
                key("0")
                Button {
                    if !entered.isEmpty { entered.removeLast() }
                } label: {
                    Image(systemName: "delete.left").font(.title2).frame(width: 72, height: 72)
                }
                .accessibilityLabel("Delete")
            }
        }
        .foregroundColor(.primary)
    }

    func key(_ d: String) -> some View {
        Button {
            if entered.count < 6 { entered.append(d); Haptics.tap() }
        } label: {
            Text(d).font(.title.weight(.medium))
                .frame(width: 72, height: 72)
                .background(Circle().fill(Color.gray.opacity(0.18)))
        }
        .accessibilityLabel("Digit \(d)")
    }
}

/// Two-step "enter, then confirm" passcode setup.
struct PasscodeSetupView: View {
    /// Sets the decoy passcode instead of the real one.
    var decoy = false
    @Environment(\.dismiss) private var dismiss
    @State private var first: String?
    @State private var entered = ""
    @State private var error: String?

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text(first == nil ? (decoy ? "Choose a decoy passcode (different from your real one)" : "Choose a 4–6 digit passcode") : "Enter it again to confirm")
                    .multilineTextAlignment(.center)
                    .font(.headline)
                Text(String(repeating: "●", count: entered.count) + String(repeating: "○", count: max(0, 4 - entered.count)))
                    .font(.title2.monospaced())
                    .accessibilityIdentifier("pinDots")
                if let e = error { Text(e).foregroundColor(.red).font(.footnote) }
                PinPad(entered: $entered)
                Button(first == nil ? "Next" : "Save Passcode") { next() }
                    .buttonStyle(.borderedProminent)
                    .disabled(entered.count < 4)
                    .accessibilityIdentifier("pinNext")
                Spacer()
            }
            .padding()
            .navigationTitle(decoy ? "Decoy Passcode" : "Set Passcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    func next() {
        if let f = first {
            if f == entered {
                do {
                    if decoy {
                        try LockManager.shared.setDecoyPasscode(entered)
                        ToastCenter.shared.show("Decoy passcode set", style: .success)
                    } else {
                        try LockManager.shared.setPasscode(entered)
                        ToastCenter.shared.show("Passcode set", style: .success)
                    }
                    dismiss()
                } catch {
                    self.error = error.localizedDescription
                }
            } else {
                error = "Those didn't match. Start again."
                first = nil
                entered = ""
            }
        } else {
            first = entered
            entered = ""
            error = nil
        }
    }
}
