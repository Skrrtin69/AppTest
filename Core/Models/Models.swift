import Foundation

// MARK: - Adapter protocol

/// Everything the UI needs from a "site". The only implementation is `GenericAdapter`,
/// which is driven entirely by an `AdapterConfig` loaded from adapters.json.
protocol SiteAdapter {
    var id: String { get }
    var displayName: String { get }
    var requiresAuth: Bool { get }
    var supportedMediaTypes: Set<MediaType> { get }
    func search(tags: [String], options: SearchOptions, page: Int) async throws -> SearchResult
    func fetchPost(id: String) async throws -> Post
    func fetchMediaURL(for post: Post, quality: MediaQuality) async throws -> URL
    func authenticate(credentials: Credentials) async throws -> AuthSession
    func validateSession(_ session: AuthSession) async -> Bool
}

// MARK: - Value types

struct SearchOptions: Codable, Hashable {
    var sort: String?
    var rating: String?
    var extra: [String: String]
    /// Cursor-paginated adapters pass the cursor from the previous page here.
    var cursor: String?

    init(sort: String? = nil, rating: String? = nil, extra: [String: String] = [:], cursor: String? = nil) {
        self.sort = sort
        self.rating = rating
        self.extra = extra
        self.cursor = cursor
    }
}

struct SearchResult {
    let posts: [Post]
    let hasNextPage: Bool
    let currentPage: Int
    let nextCursor: String?
    /// Signs the site is limiting what guests see (see GuestLimits), for a banner.
    var notes: [String] = []
}

struct Post: Codable, Hashable, Identifiable {
    let id: String
    let siteID: String
    let thumbnailURL: URL
    let mediaURL: URL
    let mediaType: MediaType
    let tags: [String]
    let sourceURL: URL?
    let metadata: [String: String]
    /// Medium-size URL if the adapter maps one (`sampleURLPath`); used for "preview" quality.
    var sampleURL: URL? = nil
    /// Tag → category (e.g. "artist") when the site provides one; used to color tags.
    var tagCategories: [String: String]? = nil

    /// Unique across sites; used for favorites, selection and SwiftUI identity.
    var key: String { "\(siteID):\(id)" }

    /// Width x height if the adapter mapped them into metadata.
    var pixelSize: CGSize? {
        guard let w = metadata["width"].flatMap(Double.init),
              let h = metadata["height"].flatMap(Double.init), w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    func with(mediaURL: URL, thumbnailURL: URL? = nil) -> Post {
        Post(id: id, siteID: siteID, thumbnailURL: thumbnailURL ?? self.thumbnailURL, mediaURL: mediaURL,
             mediaType: mediaType, tags: tags, sourceURL: sourceURL, metadata: metadata, sampleURL: sampleURL)
    }
}

enum MediaType: String, Codable, CaseIterable {
    case image, gif, video

    var label: String {
        switch self {
        case .image: return "Image"
        case .gif: return "GIF"
        case .video: return "Video"
        }
    }

    var symbol: String {
        switch self {
        case .image: return "photo"
        case .gif: return "sparkles.rectangle.stack"
        case .video: return "play.rectangle"
        }
    }
}

enum MediaQuality: String, Codable, CaseIterable {
    case original, preview
}

struct Credentials: Codable, Equatable {
    let username: String
    let password: String?
    let apiKey: String?
}

struct AuthSession: Codable {
    let siteID: String
    let token: String
    let expiresAt: Date?
    /// Sent as `authUserParamName` next to the key, for sites that want both.
    var userID: String? = nil
}

// MARK: - Errors with plain-English messages

enum AppError: LocalizedError {
    /// `message` is the server's own explanation (see ErrorParser), shown as-is.
    case http(status: Int, url: URL, message: String)
    case badResponse(String)
    case pathNotFound(field: String, path: String)
    case notJSON(String)
    case invalidURL(String)
    case authFailed(String)
    case missingCredentials(String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .http(let status, _, let message):
            // The server's words when it gave any, otherwise just the code. No per-code wording.
            return message == "HTTP \(status)" ? message : "\(message) (HTTP \(status))"
        case .badResponse(let s): return "The server's answer couldn't be understood: \(s)"
        case .pathNotFound(let field, let path):
            return "The field '\(field)' uses the path \"\(path)\", but nothing was found there in the server's answer. Use the Field Mapper to find the right path."
        case .notJSON(let snippet):
            return "The server didn't send JSON. It started with: \(snippet)"
        case .invalidURL(let s): return "This isn't a valid web address: \(s)"
        case .authFailed(let s): return "Login failed: \(s)"
        case .missingCredentials(let site):
            return "\(site) needs a login, but none is saved. Add one under Settings → Sites & Adapters → \(site) → Account."
        case .message(let s): return s
        }
    }
}
