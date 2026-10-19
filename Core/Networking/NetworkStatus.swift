import Foundation
import Network
import UIKit

/// Watches the connection type so large downloads can warn on cellular data.
final class NetworkStatus {
    static let shared = NetworkStatus()
    private let monitor = NWPathMonitor()
    private(set) var isCellular = false
    private(set) var isExpensive = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.isCellular = path.usesInterfaceType(.cellular) && !path.usesInterfaceType(.wifi)
            self?.isExpensive = path.isExpensive
        }
        monitor.start(queue: DispatchQueue(label: "network.status"))
    }

    /// True when downloads would use mobile data (or a metered hotspot).
    var onMeteredData: Bool { isCellular || isExpensive }
}

/// A yes/no question shown above whatever is on screen, awaited from async code.
enum Confirm {
    @MainActor
    static func ask(title: String, message: String, confirm: String) async -> Bool {
        await withCheckedContinuation { cont in
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in cont.resume(returning: false) })
            alert.addAction(UIAlertAction(title: confirm, style: .default) { _ in cont.resume(returning: true) })
            guard let top = Presenter.topController() else { cont.resume(returning: true); return }
            top.present(alert, animated: true)
        }
    }
}
