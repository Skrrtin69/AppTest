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
}

// MARK: - Errors with plain-English messages

enum AppError: LocalizedError {
    case http(status: Int, url: URL)
    case badResponse(String)
    case pathNotFound(field: String, path: String)
    case notJSON(String)
    case invalidURL(String)
    case authFailed(String)
    case missingCredentials(String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .http(let status, let url):
            switch status {
            case 401, 403:
                return "The server refused access (HTTP \(status)). This site probably needs a login — add one under Settings → Sites & Adapters → Account. URL: \(url.absoluteString)"
            case 404:
                return "The server says that page doesn't exist (HTTP 404). Check the Search Path / Post Path fields. URL: \(url.absoluteString)"
            case 429:
                return "The server says we're going too fast (HTTP 429). Lower 'Requests per second' for this adapter."
            default:
                return "The server answered with error code \(status). URL: \(url.absoluteString)"
            }
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
