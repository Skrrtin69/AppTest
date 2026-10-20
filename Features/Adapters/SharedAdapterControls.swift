import SwiftUI

/// Login-style chooser with a plain-English line per option. Used by the adapter form and by
/// Auto-Configure (which starts with nothing selected, because it never guesses login style).
struct AuthStylePicker: View {
    @Binding var selection: AuthStyle?

    static func title(_ s: AuthStyle) -> String {
        switch s {
        case .none: return "No login"
        case .basic: return "Username and password"
        case .apiKeyQuery: return "API key in the address"
        case .apiKeyHeader: return "API key in a header"
        case .bearer: return "API key as a bearer token"
        }
    }

    static func describe(_ s: AuthStyle) -> String {
        switch s {
        case .none: return "The site answers anyone."
        case .basic: return "Your username and password are sent with every request (HTTP Basic login)."
        case .apiKeyQuery: return "A key is added to the web address, like ?api_key=… Fill in the key's name below."
        case .apiKeyHeader: return "A key is sent invisibly as a header, like X-Api-Key: … Fill in the header's name below."
        case .bearer: return "A key is sent as Authorization: Bearer … (common for newer APIs)."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(AuthStyle.allCases, id: \.self) { style in
                Button {
                    selection = style
                    Haptics.tap()
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: selection == style ? "largecircle.fill.circle" : "circle")
                            .foregroundColor(selection == style ? .accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.title(style)).foregroundColor(.primary)
                            Text(Self.describe(style)).font(.caption).foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(Self.title(style))\(selection == style ? ", selected" : "")")
            }
        }
    }
}

/// Username / password / API key inputs. Opted out of iOS password AutoFill on purpose.
struct CredentialFields: View {
    @Binding var username: String
    @Binding var password: String
    @Binding var apiKey: String

    var body: some View {
        TextField("Username", text: $username)
            .textInputAutocapitalization(.never).disableAutocorrection(true)
            .textContentType(.oneTimeCode)
            .accessibilityIdentifier("acct-username")
        SecureField("Password (optional)", text: $password)
            .textContentType(.oneTimeCode)
            .accessibilityIdentifier("acct-password")
        TextField("API key (optional)", text: $apiKey)
            .textInputAutocapitalization(.never).disableAutocorrection(true)
            .textContentType(.oneTimeCode)
            .accessibilityIdentifier("acct-apikey")
    }
}

/// A failure explained in plain English, with the one thing to do next.
struct ErrorCard: View {
    let title: String
    let message: String
    let next: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundColor(.orange)
            Text(message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text("Next: \(next)").font(.subheadline.weight(.semibold))
            if let t = actionTitle, let a = action {
                Button(t, action: a).buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("errorCard")
    }
}

/// Colored dot for a confidence level.
struct ConfidenceDot: View {
    let level: Confidence
    var color: Color {
        switch level {
        case .high: return .green
        case .medium: return .yellow
        case .low: return .red
        }
    }
    var body: some View {
        Circle().fill(color).frame(width: 10, height: 10)
            .accessibilityLabel(level.label)
    }
}

/// One result row, shared by Test adapter and the Auto-Configure preview.
struct ResultPreviewRow: View {
    let post: Post
    var warnings: [String] = []

    var body: some View {
        HStack(spacing: 10) {
            CachedAsyncImage(url: post.thumbnailURL, maxPixel: 160)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text("ID \(post.id)").font(.subheadline.monospaced())
                Text("\(post.mediaType.label) · \(post.tags.prefix(4).joined(separator: " "))")
                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
                ForEach(warnings, id: \.self) { Text($0).font(.caption2).foregroundColor(.orange) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("testResult")
    }
}

/// A result that couldn't be turned into a post, with the failing fields in red.
struct FailedResultRow: View {
    let index: Int
    let problems: [AdapterConfig.CodingKeys: String]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "xmark.octagon.fill").foregroundColor(.red).frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text("Result \(index + 1) can't be shown").font(.subheadline.weight(.semibold))
                ForEach(problems.keys.sorted { $0.rawValue < $1.rawValue }, id: \.self) { k in
                    Text(problems[k] ?? "").font(.caption.monospaced()).foregroundColor(.red)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("failedResult")
    }
}
