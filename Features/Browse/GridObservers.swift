import SwiftUI
import Combine

/// The few settings a grid thumbnail draws with. Thumbnails watch this instead of all of
/// AppSettings, so changing an unrelated setting (playback speed, slideshow interval, the
/// viewer background…) no longer redraws every thumbnail in every tab.
final class GridLook: ObservableObject {
    static let shared = GridLook()
    struct Values: Equatable {
        var blur = false, dim = true, smart = true, animate = true
    }
    @Published private(set) var v: Values
    private var sub: AnyCancellable?

    private init() {
        v = Self.read()
        // objectWillChange fires just before the change lands: read on the next turn.
        sub = AppSettings.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    private static func read() -> Values {
        let s = AppSettings.shared
        return Values(blur: s.blurThumbnails, dim: s.dimViewed, smart: s.smartThumbnails, animate: s.gridGIFsAnimate)
    }

    private func refresh() {
        let n = Self.read()
        if n != v { v = n }
    }
}

/// Which posts are favorites, for the heart on thumbnails. LibraryStore also publishes
/// history and saved searches (every search changes history); this only changes with the
/// favorites themselves.
final class FavoriteMarks: ObservableObject {
    static let shared = FavoriteMarks()
    @Published private(set) var keys: Set<String>
    private var sub: AnyCancellable?

    private init() {
        keys = LibraryStore.shared.favoriteKeys
        sub = LibraryStore.shared.$favoriteKeys
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] k in self?.keys = k }
    }
}
