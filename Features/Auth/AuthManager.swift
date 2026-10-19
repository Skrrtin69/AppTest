import Foundation

/// Per-adapter login state. Credentials live in the Keychain; sessions are kept in memory.
final class AuthManager: ObservableObject {
    static let shared = AuthManager()

    enum Status: Equatable {
        case notNeeded, notConfigured, loggedOut, loggedIn, failed(String)
        var label: String {
            switch self {
            case .notNeeded: return "No login needed"
            case .notConfigured: return "No account saved"
            case .loggedOut: return "Account saved (not logged in yet)"
            case .loggedIn: return "Logged in"
            case .failed(let m): return "Login failed: \(m)"
            }
        }
        var isGood: Bool { self == .loggedIn || self == .notNeeded }
    }

    @Published private(set) var statuses: [String: Status] = [:]
    private var sessions: [String: AuthSession] = [:]

    func cachedSession(for id: String) -> AuthSession? { sessions[id] }

    func status(for config: AdapterConfig) -> Status {
        if let s = statuses[config.id] { return s }
        if !config.requiresAuth && config.authStyle == .none { return .notNeeded }
        let hasCreds = (try? Keychain.credentials(for: config.id)) != nil
        return hasCreds ? .loggedOut : (config.requiresAuth ? .notConfigured : .notNeeded)
    }

    func credentials(for id: String) -> Credentials? {
        do { return try Keychain.credentials(for: id) } catch {
            ToastCenter.shared.error(error)
            return nil
        }
    }

    func saveCredentials(_ c: Credentials?, for id: String) throws {
        try Keychain.setCredentials(c, for: id)
        sessions[id] = nil
        AdapterRegistry.shared.adapter(for: id)?.session = nil
        DispatchQueue.main.async { self.statuses[id] = nil }
    }

    /// Logs in with the stored credentials.
    @discardableResult
    func login(adapter: GenericAdapter) async throws -> AuthSession {
        guard let creds = try Keychain.credentials(for: adapter.id) else {
            throw AppError.missingCredentials(adapter.displayName)
        }
        do {
            let s = try await adapter.authenticate(credentials: creds)
            sessions[adapter.id] = s
            adapter.session = s
            await MainActor.run { statuses[adapter.id] = .loggedIn }
            return s
        } catch {
            await MainActor.run { statuses[adapter.id] = .failed(error.localizedDescription) }
            throw error
        }
    }

    /// Called before requests to adapters that need auth: validates the current session and,
    /// if it's gone or invalid, logs in again with the stored credentials.
    func ensureSession(for adapter: GenericAdapter) async throws {
        let needsAuth = adapter.requiresAuth
        let hasCreds = (try? Keychain.credentials(for: adapter.id)) != nil
        guard needsAuth || (adapter.config.authStyle != .none && hasCreds) else { return }
        if let s = sessions[adapter.id] ?? adapter.session, await adapter.validateSession(s) {
            adapter.session = s
            return
        }
        if !hasCreds && !needsAuth { return }
        try await login(adapter: adapter)
    }

    func logout(_ id: String) {
        sessions[id] = nil
        AdapterRegistry.shared.adapter(for: id)?.session = nil
        statuses[id] = nil
    }
}
