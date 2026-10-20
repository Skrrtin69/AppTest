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

## Phase 15
- **Masonry** is laid out in code: each post goes to the currently shortest column, using its known width × height (square if unknown), with one lazy column per stack. Pagination still uses each post's overall index, so loading more works the same as in the normal grid.
- **Read Later lives in UserDefaults** (JSON), not Core Data, to avoid changing the code-defined model. It hides in decoy mode and is included in backups.
- **Tag translations are display-only plus a reverse lookup on search.** Adapters, the blacklist and saved data always keep the site's real tags; only chips show your name, and search words are mapped back before the request.
- **Buttons inside a grid's scroll view didn't respond** (Read Later's Clear Viewed), so headers with buttons sit above the scroll view.
- **The search builder edits the current tab** (query, sort, rating), and the search bar refreshes when the builder closes.

## Phase 16
- **Vision runs on its own serial utility queue** (with `preferBackgroundProcessing`), not in a Swift `Task.detached`. On the device, detached Vision tasks never got a thread while the grid loaded, so thumbnails stayed blank. The plain thumbnail shows at once and the smart crop replaces it. Focus points are cached in memory and in `Caches/SmartCropFocus.json`, and animated GIFs are never cropped.
- **Smart collections are rules stored in UserDefaults** and evaluated against favorites each time, so they never go stale. They're included in backups.
- **Local suggestions** are weighted: favorites ×3, Read Later and history ×2, open results ×1, and translated names ×5 (suggesting the site's tag).
- **Gesture remapping:** double tap goes through the zoom view's own recognizer, so single taps still wait for it as before. Swipe up/down reuse the viewer's drag gesture.
- **External display was removed.** A separate scene for a TV needs `application(_:configurationForConnecting:)`, and implementing it (returning either the session's configuration or a fresh default for the app window) left the app's own SwiftUI window black on launch. Without it, iOS simply mirrors the phone to the TV.

## Phase 17
- **All Vision work** (text, feature prints, saliency) runs on dedicated serial utility queues with `preferBackgroundProcessing`, and results are cached per address. Text recognition runs only when asked, to save battery.
- **Look-alike matching is relative:** feature-print distances use different scales across iOS versions, so pairs closer than a fraction of the median distance (0.5 / 0.33 / 0.18) are grouped with union-find. The numbers are logged in the debug console for tuning.
- **Watching saved searches** uses `BGAppRefreshTask` (iOS decides when; it can't be forced) plus a check on opening. State lives in UserDefaults per saved-search ID. The first check only records what's there, so nothing counts as "new" right away. Notifications are only sent while the app is in the background; in the app a message is shown instead.
- **Debug log masking:** query values whose names contain key, token, pass, secret, auth, session, user_id or sig are replaced before a line is stored.
- **Messages moved to the bottom of the screen.** At the top, a message's Undo sat exactly where sheets have Done, so a quick Done tap undid the action (found while testing look-alikes).

## Phase 18 (trimmed)
- Live Activities, QR sharing, read aloud and AI subject blur were dropped at the owner's request: nothing on the Lock Screen, no talking, and the manual blur is enough.
- **Deep links** reuse the existing router: a numbers-only search opens that post. The same link arriving twice within 2 s is ignored, because a link that launches the app is delivered twice.
- **Upscaling** only applies to the saved file (Lanczos + 0.4 luminance sharpen); the preview stays small.

## Phase 19
- **ZIP reading** is built in (central directory; stored and deflate via the Compression framework), so no library is needed. Timings: site JSON (registered when results are mapped), else animation.json, else 100 ms. UIImage animations have one frame length, so longer frames are repeated to approximate their delay.
- **Any multi-frame image ImageIO can read animates** (GIF, WebP, APNG), reading delays from each format's own dictionary.
- **HLS always uses AVPlayer.** The playability check found no video tracks in an HLS asset before playback and sent it to the web player, which can't play it.
- **Empty and HTML answers** are rejected before decoding everywhere: the request layer (status and Content-Type), the decoder (for local files) and downloads (size 0, or a text/html Content-Type).

## Phase 20
- **CBZ** pages keep their real type: the address's extension, else sniffed from the first bytes. Names are zero-padded to at least 3 digits.
- **Pools** come either from a list of post IDs (fetched one by one in order, capped at 500) or from a search template (paged, capped at 1000).
- **Six tabs would push Settings under iOS's "More"**, so Downloads moved into the Library, and the queue count shows as the Library tab's badge.
- **Mass reverse search** runs sequentially with a 1.5 s pause between requests. "Duplicates" means selected posts whose best match is the same source address, or a match that points to a different post on one of your sites.
- **Fallback** is offered only when the first page fails with a timeout, connection error, 429 or 5xx, and only if a fallback site is chosen. Nothing switches without a tap.

## Reverse search upload fix
- **Cause of "You need an Image!":** in upload mode, the engine address still carried `url={url}` filled with the picture's address. The engine used that address (unreachable for 127.0.0.1, or competing with the file) instead of the uploaded file. Upload mode now removes any query item containing `{url}` and keeps everything else (`output_type`, `api_key`, …).
- **The upload is always a still JPEG** (max 2000 px) in one multipart part named by `uploadField` (default `file`), with `filename="image.jpg"`, `Content-Type: image/jpeg`, and the boundary in the request's Content-Type. Videos use their first frame (AVAssetImageGenerator, with the site's headers), falling back to the thumbnail for WebM. GIF, WebP, APNG and ZIP animations use their first frame. Transparent pictures are flattened onto white.
- **Redirects keep the POST body** (a dedicated session re-sends method, body and headers).
- **Engine errors:** a negative `header.status` (even with HTTP 200), or an HTTP error, shows the engine's `header.message` with HTML tags, entities and literal `\uXXXX` escapes removed.
- The demo engine now rejects uploads that aren't a multipart `file` picture, or that also send `url=`, so this is covered by tests on the demo server.
- **Empty match paths are guessed:** if an engine leaves Similarity, Thumbnail, Source link or Title empty, each match is searched for keys named like `similarity`/`score`, `thumb`/`preview`, `url`/`source`/`link` (the first web link that isn't the thumbnail) and `title`/`material`/`source`/`creator`/`author`/`*_name`. Filled-in paths always win.

## Log in to find my key
- **Finding the key by context, not by length:** the key is found by what it's labeled with (label text, `name=` in example addresses, labeled text boxes), not by picking the longest string. Pages also show session codes, hashes and IDs, and the demo account page has one (`Session: …`) that is correctly ignored.
- **Values the reader skips:** hidden inputs are skipped (they're usually form tokens), and so are password boxes (the user's own password must never be read). A value counts as a key only if it has 8+ characters with a digit, or 20+ characters.
- **No automatic login:** the user logs in on the site themselves; the app never fills in or reads their password.
- **Re-analyze:** after a key is picked, Analyze runs again on its own so the adapter is ready to save. Nothing is saved without tapping Save.

## Connection wizard
- **No login style picker:** Test Connection tries the four usual ways of sending a key (address, Bearer, X-Api-Key, key + user ID) in a fixed order and keeps the first that the site accepts. A success saves the adapter right away, as asked. Username and password logins stay available behind a switch, because some sites (the demo Secure site among them) only accept those.
- **Probe speed:** probing uses a separate network client with a 5-second timeout and no retries. Without this, a single https attempt against a plain-http server waited for the normal timeout and retried three times, which the user saw as a hang on "Analyzing". Adapters keep their own timeout and retries.
- **Scheme guessing:** https is assumed for typed addresses, except local ones (127., 192.168., 10., localhost), which use http. Only a guessed https falls back to http; a typed `https://` is never downgraded.
- **Default address:** when nothing resolves, the field gets `/posts.json?tags={tags}&page={page}`, the most common shape, for the user to check.
- **Auth messages in non-JSON answers:** a text or HTML answer counts as "needs a login" only when it is short (at most 3,000 visible characters after removing tags, scripts and styles) and contains one of a fixed list of phrases ("missing authentication", "api key required", "unauthorized", "login required", "403 forbidden", "access denied"…). The length limit keeps a normal home page, which may contain "please log in" somewhere, from stopping the resolver. With a key already sent, the same answer means the key was refused, so the background tester moves on to the next way of sending it.

## Tag post counts
- **Lookup through suggestions:** counts come from the suggestions address that adapters already have, not from a separate tag-lookup address. Tag Info searches suggestions for the tag itself and keeps only an exact match (case- and space/underscore-insensitive).
- **Count keys:** a count is read from `tagCountPath`, or the first of the usual keys that holds a number (numbers written as text, with or without thousands separators, count too).
- **Rejecting false suggestion addresses:** Auto-Configure rejected nothing before, and the owner's Danbooru adapter got `tags.json?q={query}`. That site ignores `q` and returns its newest tags, so suggestions were unrelated and Tag Info found nothing. Now at least one of the first 20 suggestions must contain the typed text. `tags.json?search[name_matches]={query}*&search[order]=count` was added to the address shapes tried. Square brackets in addresses are now percent-encoded, which older iOS versions require.
