# Decisions

Choices made while building MediaDeck, and why.

## Build & packaging
- **No Mac available → GitHub Actions `macos-15` runner.** The workflow (`.github/workflows/build.yml`) installs XcodeGen + ldid, generates the Xcode project, builds, and uploads the IPA (and a fallback .deb) as artifacts.
- **XcodeGen (`project.yml`) instead of a committed `.xcodeproj`.** A hand-written pbxproj is fragile; the project is generated on every CI run.
- **Unsigned build + `ldid` fakesign** with `Support/MediaDeck.entitlements`, packaged as `MediaDeck.ipa`. TrollStore installs this directly. The .deb (`scripts/build_deb.sh`) is a rootless-layout fallback; roothide converts rootless packages.
- **Sample clips are generated once with ffmpeg test sources (`scripts/make_media.sh`) and committed** (~280 KB total) so CI doesn't need ffmpeg. PNGs and GIFs are drawn at runtime by the demo server instead of being bundled.

## Platform
- **Target iOS 15, test device iOS 16.2.** SwiftData requires iOS 17, so **Core Data** is used, with the model defined in code (`CoreDataStack.swift`): no `.xcdatamodeld` to maintain.
- **`NavigationView` (stack style)** instead of `NavigationStack` (iOS 16+), to keep iOS 15 support.
- **Swift 5 language mode** to avoid Swift 6 strict-concurrency errors; actors are still used for the cache, rate limiter, semaphore and playback router.

## Architecture
- `SiteAdapter` protocol → single `GenericAdapter` driven by `AdapterConfig`. **No site-specific code exists.**
- **Extra optional AdapterConfig fields** beyond the spec, all JSON-editable and defaulted when missing: `sampleURLPath`, `postResultPath`, `metadataPaths`, `authCheckPath`, `tagSeparator`, `firstPageIndex`, `sortOptions`, `ratingOptions`, `userAgent`, `proxyHost`, `proxyPort`, `timeoutSeconds`, `headers`. Reasons: per-adapter proxy/UA (spec'd in Settings) should also live in JSON; sort/rating pickers need a list of choices; dimensions in the info panel need metadata mapping.
- **Spec fields are `var` instead of `let`** so the editor form can bind to them directly.
- **Exported adapters.json writes every key (null when empty)**, so a user opening the file sees every field that exists.
- **Auth model:** `basic` sends `Authorization: Basic …`; `apiKeyQuery` appends `authParamName=key`; `apiKeyHeader` sends header `authParamName: key`. "Logging in" builds the token and, if `authCheckPath` is set, verifies it against the server. `validateSession` re-checks that path; auto re-login happens in `AuthManager.ensureSession` before every search.
- **Rate limiting** applies to API requests (search/post). Media and thumbnail loads are instead bounded by the "simultaneous thumbnail loads" slider, so a grid of 60 thumbnails isn't throttled to the API rate.
- **`adapters.json` is copied to Documents on first launch**, which makes it visible in Files › On My iPhone › MediaDeck. Edits there hot-reload via a directory watcher. If the user's file is broken, the app shows a plain-English error and falls back to the bundled list.
- **Demo-server port:** bundled JSON uses `127.0.0.1:8765`. If 8765 is taken, the server binds the next free port and the registry rewrites `127.0.0.1:8765` → actual port in memory when decoding.

## Demo server
- `NWListener` (Network.framework) bound to 127.0.0.1; one request per connection; supports byte ranges (AVPlayer needs them) and HEAD.
- Site A: flat JSON, page numbers, absolute URLs. Site B: nested JSON (`data.items[].post.media.*`, `tag_list[{name}]`), cursor pagination, **relative** media URLs (exercises `mediaBaseURL`). 60 posts each, 20 per page → 3 pages.
- `/a/secure/...` requires login (user `demo` / password `demo`, or API key `demo-key`) to exercise `requiresAuth`.

## UX decisions
- **Long-press conflict:** the spec asks for long-press context menus and long-press-to-enter-multi-select. iOS gives long-press to the context menu, so **the context menu's first item is "Select"**, which enters multi-select with that item selected. A "Select" entry is also in the toolbar menu.
- **Multiple searches as tabs** are a chip strip under the search bar. All tab grids stay mounted (hidden ones are transparent) so each keeps its scroll position and pagination.
- **Viewer paging** uses `TabView` page style. Each page's zoom is a `UIScrollView`. At 1× it can't scroll sideways, so swipes page between posts. Only pages within ±2 of the current one are rendered, and their media is prefetched.
- **Video routing** is decided at runtime per URL: AVFoundation `isPlayable` + has a video track → AVPlayer; otherwise → WKWebView `<video>`. If AVPlayer fails later, the URL is re-routed to the web player. A small label in the viewer shows which player is active.
- **WebM in WKWebView:** private WebKit feature flags containing "WebM"/"Vorbis"/"Opus" are switched on at runtime when present (selectors are looked up dynamically; no-op otherwise).
- **Photos export skips WebM** (Photos can't store it) and says so; Files export handles everything.
- **Theme:** AMOLED = dark mode + pure-black UIKit chrome via appearance proxies; the tab view is rebuilt on theme change so proxies apply.
- **Passcode** is stored as a salted SHA-256 hash in the Keychain; biometrics are only offered once a passcode exists. A privacy cover hides content in the app switcher.
- **"Check for updates"** opens a user-editable URL defaulting to `https://updates.invalid/mediadeck` (`.invalid` is a reserved, never-resolving TLD).

## Decisions made during device testing
- **WebM → bundled ogv.js.** WebKit on iOS 16.2 can't play WebM and has no WebM feature flags to switch on. The app's local server now serves a player page (`/player/video.html`) plus the ogv.js files. The page tries WebKit `<video>` first and falls back to ogv.js (WebAssembly VP8/VP9, with SIMD and threads off since 16.2 lacks them). Downloaded files are served at `/local/…`; remote files go through `/proxy` so the decoder isn't blocked by CORS. Vendored, not downloaded at runtime.
- **Background downloads fall back automatically** when the background session's temp file can't be read (see BLOCKERS.md #1). The setting stays, and the fallback is remembered.
- **Toasts and the lock screen live in a separate overlay window** above all sheets and full-screen covers. Inside the normal view tree, toasts were invisible behind sheets, and the lock screen sat *below* an open viewer (a privacy hole). The window ignores touches unless it is locked or covered.
- **The adapter editor sheet can't be swiped away**, only closed with Cancel or Save, so unsaved work isn't lost.
- **Account fields opt out of iOS password AutoFill** (`textContentType(.oneTimeCode)`). During testing, iOS offered and filled in the phone owner's saved login for an unrelated site.
- **Pull-to-refresh fetches page 1 before replacing the grid.** Clearing first tore down the scroll view running the refresh and cancelled the request.
- **adapters.json is written with keys in form order.** JSONEncoder's order is arbitrary, which is confusing when editing by hand.
- **Demo video downloads are throttled** (~20 KB/s, only for requests whose User-Agent is the app's downloader) so the queue's pause/resume/cancel can be demonstrated. Playback is never throttled.
- **Disabling a site moves any open tabs on it** to the first enabled site.
- **The tab chip's close button is its own accessibility element**, so VoiceOver and automation can reach it.
