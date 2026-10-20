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

## Auto-Configure
- **Result list:** every array of objects reachable through objects is scored (+3 length ≥ 3, +2 identical key sets, +2 list-like name, +1 contains a URL, +1 child of root); highest wins.
- **Profiling:** the first three results' leaf paths (arrays are leaves); only paths present in all three are classified as URL, file type, tags, ID, or source.
- **URL roles:** thumbnail keywords are checked before media keywords. A key with "sample" becomes the medium-size address unless it's the only thumbnail-like key. Web addresses without a media file ending are source candidates, not media.
- **Media base:** relative addresses are test-loaded against the API folder, then the site root; the first that loads wins (high), otherwise low.
- **Confidence:** high = key name explicitly matches the role (or the value is taken directly from your input); medium = shape agrees across all three results, or a safe default; low = single/ambiguous candidate or no evidence. Every field always gets a specific sentence.
- **postPath** can't be derived when no single-post address appears in the results. It's marked medium "needs input (optional)", not low, because browsing doesn't use it; otherwise every site would get a review badge.
- **IDs for numeric/local hosts** append the first path folder (e.g. 127-0-0-1-a), since the host alone can't tell sites apart.
- **Login style is never guessed:** 401/403 stops with a picker that starts with nothing selected.
- **Review badges:** guesses are stored per adapter with their proposed value; a low guess stops counting as soon as the field's value changes or the user taps "Mark all as reviewed".

## Phases 1–8
- **WebM audio:** no remuxing library. Remuxing VP8/VP9 into MP4 doesn't help, because AVPlayer on iOS still can't decode that video, and the remux libraries are retired. The ogv.js decoder already in the app plays the Vorbis/Opus audio. When a post also has an MP4 (`alternateMediaURLPaths`), the MP4 is used.
- **Errors:** `ErrorParser` reads common message keys (message, error, detail, description, errors[]…), or an HTML title, and shows them verbatim. No per-status wording.
- **Merged search:** sites are queried in parallel (TaskGroup) with their own page/cursor. Results are interleaved; duplicates are dropped by post key, and by identical media URL only across *different* sites.
- **Media requests:** one path (`NetworkClient.mediaData`) adds the adapter's headers and a default Referer (the adapter's base address), upgrades public http→https with an http fallback, and rejects HTML and empty answers. AVPlayer gets the same headers through its asset options; the web player goes through the in-app proxy.
- **Not built, by choice:**
  - automatic API discovery and capability probing
  - automatic key-location testing, and scraping keys from web pages
  - CAPTCHA-backed web scraping for reverse search
  - iCloud sync

  Instead, Auto-Configure reports Public / Requires auth from one normal search and shows the site's own error wording; you choose how the key is sent. Site pages open themed, with a Copy Selection button.
- **Favorites sync state** is stored as a key set in UserDefaults, not as a new Core Data attribute. The Core Data model is defined in code, so changing it could force a store reset.
- **Delete with Undo:** Library deletions wait 5 seconds (items are hidden meanwhile) before files are removed.
- **Custom themes** are stored as hex colors, so the same values feed SwiftUI, UIKit appearance proxies, and the injected web-page CSS.

## Phases 9–10
- **Auto-advance** is one global setting (`autoAdvance`), not per post. Video end is reported by AVPlayer's end notification, or by the web player's `ended` event. Only the page that is on screen may advance the viewer, so preloaded neighbours can't skip ahead.
- **Galleries** keep the post model flat: `Post.pages` is an optional list of URLs, and `mediaURL` stays the first page. Favorites, downloads and the Info panel keep working unchanged. Each page becomes a temporary single-picture post (`post.page(i)`) only for display.
- **Tall images:** when a picture is more than 2.5× taller than wide, the requested size is used as its *width*. No decode goes above about 24 megapixels, so a 720×6000 strip stays sharp, and a huge scan can't exhaust memory.
- **Gestures in galleries:** swipe-down-to-close and the edge brightness/volume sliders are off on gallery posts, because the gallery scrolls vertically itself. Close with ✕.

## Phase 11
- **Right-to-left** reverses the pager's page order instead of mirroring the layout. Mirroring also flipped the UIKit zoom view inside each page, so pictures showed zoomed and off-centre, and swiping stopped working.
- **Tap zones** use the tap position reported by the zoom view's own single-tap recognizer, so double-tap-to-zoom keeps working. Taps are ignored while zoomed in.
- **Battery Saver** is computed, not stored: `savingPower` = "on", or "auto" plus iOS Low Power Mode. It updates live through the power-state notification. Grid images reload when animation is switched, so GIFs stop or start at once.
- **Cache expiry** uses the file's modification date, which the cache refreshes on every read, so the setting means "not opened in N days". It runs at launch, when the setting changes, and before each size trim.
- **Toolbar customization** stores the buttons moved into the menu (`hiddenViewerButtons`). Close, the counter and Info are always shown. A new button defaults to the menu, so the bar never overflows.
- **Rotation lock** has to refresh every controller in the presentation chain, because the viewer is a SwiftUI full-screen cover over the root. The request is sent after the cover finishes appearing, and closing the viewer goes back to automatic.

## Phase 12
- **Reverse search engines are user-defined JSON** (`reverse_search.json`), the same idea as adapters. No real service is named or built in: the only bundled engine talks to the demo server. Only JSON APIs are supported, with no reading of web pages meant for browsers. API keys live in the Keychain.
- **Uploads vs links:** a picture on 127.0.0.1 can't be fetched by an outside service, so it's always uploaded (multipart), whatever the engine's mode.
- **Copied-link detection** first only asks iOS *whether* the clipboard holds a link (`detectPatterns`), which needs no permission. The text is read only after the user taps Open. Asking right at activation is refused, so the check waits 0.8 s and retries once. If detection stays unavailable, it falls back to the clipboard's "contains a link" flag.
- **Link → site:** the site's whole base path must be a prefix of the link's path, longest first (so `/a/view/52` isn't sent to the `/a/secure` site). If no path fits, any site on the same host is used, and the open site wins ties. Post IDs come from `id=`, or from the last path part containing a digit.
- **Muted uploaders are blacklist entries** (`uploader:name`), so there's one list to manage and one filter. No new adapter field: the uploader is an ordinary `metadataPaths` entry.
- **Viewer pages are transparent** now: each page used to paint black, which hid the white/checker/color backdrop in paged mode.
- **Toasts:** tap-to-dismiss sits on the message text only. On the whole row it swallowed taps on Undo/Open, so Undo had silently stopped working.
- **Deploy script** sends the app to the background before killing it, so iOS saves recent settings changes first.

## Phase 13
- **Decoy mode is a view filter, not a second database.** While it's on, the library store reports empty lists and ignores writes. Downloads and the adapters list are filtered to nothing and to the bundled demo IDs. "Delete all" style actions show their usual message but touch nothing, so they can't be used to wipe real data. The flag lives only in memory: every lock and unlock decides again, and Face ID always means the real owner.
- **The decoy code is stored like the real one** (salted SHA-256 in the Keychain). It must differ from the real code, and turning the passcode off removes it.
- **Backups are merge-only.** Restoring never deletes or overwrites library items, adapters, themes or engines whose ID already exists. Settings are the exception: they're replaced, because they're one set of values. Secrets stay in the Keychain and are never exported.
- **Charts** is iOS 16-only, so it's weak-linked (`-weak_framework Charts`) and iOS 15 gets simple drawn bars.
- **Tag actions use `Menu` with a primary action**, not `.contextMenu`. Inside a List row, SwiftUI gives the whole row the first context menu, so every tag showed the first tag's actions.
- **iPad multitasking:** `UIRequiresFullScreen = false`, plus columns based on the horizontal size class, so a narrow Split View pane gets the phone layout.

## Phase 14
- **Two app extensions** (widget, share) share files with the app through the app group `group.com.skrrtin69.mediadeck`. The build script fakesigns each extension with its own entitlements before the app. Nothing is shared but files: an `Inbox/` folder from the share sheet, and a `Widget/` folder with up to 24 favorite thumbnails plus `feed.json`. The widget never touches the network or the database.
- **The share extension opens MediaDeck** by calling the application object's `openURL:options:completionHandler:` through the responder chain, because extensions can't use `UIApplication.shared`. If that ever stops working, items wait in the inbox until the next launch.
- **Shared pictures are presented from the topmost screen, retrying while the share sheet is still closing.** A SwiftUI sheet on the root silently fails while the viewer covers the screen.
- **Picture in Picture** reuses the existing AVPlayerLayer. While PiP runs, the controller is kept in `VideoController.floating`, so closing the viewer doesn't stop the video. It's torn down when PiP ends.
- **The scroll-to-top button** watches a lazy marker at the top of the grid (it disappears once scrolled away). A scroll-offset preference was unreliable, because the grid next to the marker kept reporting the default value.
- **EXIF demo:** every third full-size demo picture is served as a JPEG with made-up camera data, and every sixth also has a made-up location.
