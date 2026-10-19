import SwiftUI
import LocalAuthentication
import CryptoKit

/// App-level passcode (4–6 digits, stored hashed in the Keychain) with optional Face ID /
/// Touch ID. Locks when the app goes to the background and the grace period has passed.
final class LockManager: ObservableObject {
    static let shared = LockManager()

    @Published private(set) var isLocked = false
    @Published private(set) var hasPasscode = false
    @Published var obscured = false   // privacy cover while in the app switcher
    private var backgroundedAt: Date?
    private let account = "app-pin"

    private init() {
        hasPasscode = (try? Keychain.get(service: Keychain.pinService, account: account)) != nil
        isLocked = hasPasscode
    }

    static func hash(_ pin: String) -> Data {
        Data(SHA256.hash(data: Data("mediadeck-pin:\(pin)".utf8)))
    }

    func setPasscode(_ pin: String) throws {
        guard (4...6).contains(pin.count), pin.allSatisfy(\.isNumber) else {
            throw AppError.message("The passcode must be 4 to 6 digits.")
        }
        try Keychain.set(Self.hash(pin), service: Keychain.pinService, account: account)
        hasPasscode = true
    }

    func removePasscode() throws {
        try Keychain.delete(service: Keychain.pinService, account: account)
        hasPasscode = false
        isLocked = false
        AppSettings.shared.biometricsEnabled = false
    }

    func verify(_ pin: String) -> Bool {
        guard let stored = try? Keychain.get(service: Keychain.pinService, account: account) else { return false }
        return stored == Self.hash(pin)
    }

    func unlock(with pin: String) -> Bool {
        if verify(pin) {
            isLocked = false
            Haptics.success()
            return true
        }
        Haptics.error()
        return false
    }

    var biometryName: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "Biometrics"
        }
    }

    var biometricsAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    @MainActor
    func unlockWithBiometrics() async {
        guard hasPasscode, AppSettings.shared.biometricsEnabled, biometricsAvailable else { return }
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Enter Passcode"
        do {
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Unlock MediaDeck")
            if ok { isLocked = false; Haptics.success() }
        } catch {
            // User cancelled or failed; the passcode pad stays available.
        }
    }

    func lockNow() {
        if hasPasscode { isLocked = true }
    }

    // MARK: Scene phase

    func didEnterBackground() {
        backgroundedAt = Date()
        obscured = hasPasscode
    }

    func willEnterForeground() {
        obscured = false
        guard hasPasscode, !isLocked else { return }
        let elapsed = Date().timeIntervalSince(backgroundedAt ?? .distantPast)
        if elapsed >= Double(AppSettings.shared.lockGraceSeconds) { isLocked = true }
    }
}
