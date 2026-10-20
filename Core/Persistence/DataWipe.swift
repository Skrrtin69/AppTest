import Foundation
import Security
import UIKit
import CoreData

/// "Forgot Passcode?": erases everything MediaDeck keeps on this phone, then closes the app so
/// the next launch starts fresh (no passcode, built-in demo adapters, default settings).
enum DataWipe {
    static func eraseEverything() {
        let fm = FileManager.default
        // Library, history, saved searches, download records.
        let ctx = CoreDataStack.shared.context
        for name in ["Favorite", "Collection", "History", "SavedSearch", "Download"] {
            let r = NSFetchRequest<NSManagedObject>(entityName: name)
            ((try? ctx.fetch(r)) ?? []).forEach(ctx.delete)
        }
        try? ctx.save()
        // Every Keychain item of the app: passcode, decoy code, logins, API keys.
        for cls in [kSecClassGenericPassword, kSecClassInternetPassword] {
            SecItemDelete([kSecClass as String: cls] as CFDictionary)
        }
        // Settings and everything stored next to them.
        if let id = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: id)
            UserDefaults.standard.synchronize()
        }
        // Files: downloads, adapters.json and the other JSON files, caches, app-group items.
        let roots = [fm.urls(for: .documentDirectory, in: .userDomainMask)[0],
                     fm.urls(for: .cachesDirectory, in: .userDomainMask)[0],
                     fm.temporaryDirectory] + [AppGroup.container].compactMap { $0 }
        for root in roots {
            for u in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                try? fm.removeItem(at: u)
            }
        }
        DebugLog.log("Wipe", "All local data erased")
        // A clean start: the app closes and opens fresh next time.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
    }
}
