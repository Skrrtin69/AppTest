# MediaDeck Roadmap

Status per item is tracked in commits and in BLOCKERS.md.

## Pre-Phase: Critical Bug Fixes
- **Crash on malformed URL / HTML response:** typing `&api_key` in Auto-Configure's Key Name and tapping Analyze crashes. Sanitize key names (strip leading `&`/`?`), never force-unwrap `URL(string:)`, wrap decoding in do/catch, and turn HTML answers into a clean error.
- **Keyboard trap and accidental Cancel:** remove Cancel from the Auto-Configure bottom bar (Back already exits) and replace it with a Done button that dismisses the keyboard via `@FocusState`. Add a keyboard toolbar "Done" to all forms.
- **Empty-array crash and server delay:** the Field Mapper crashes on `"posts": []`; show "0 results" instead. Give the mock server a startup delay/retry so Auto-Configure doesn't hang on launch.

## Phase 1: Audio, Errors, and Tags
- **Media selection:** prefer MP4 over WebM when both exist (native AVPlayer audio).
- **WebM audio:** for WebM-only files, attempt remuxing to MP4 (e.g. MobileFFmpeg/VLCKit) so audio plays.
- **Universal error handling:** parse API error responses generically (`message`, `error`, `detail`…) and show that text instead of generic HTTP codes.
- **Tag parsing:** `tagSpaceReplacement` in config (auto-detect underscores/hyphens); `autocompletePath` for debounced search suggestions.

## Phase 2: Merged Multi-Site Search
- A "Merged Search" mode that queries all enabled adapters at once, merges and deduplicates results, and shows a source indicator on each thumbnail.
- Independent pagination per site. If one site fails, show the rest with a subtle banner.

## Phase 3: Search, Discovery & Performance QoL
- **Tag chips:** visual pills for active tags.
- **Random and ID search:** pure numbers go to the ID endpoint; a dice button adds random.
- **Navigation:** jump to page, scroll to top, sticky sort/rating per site.
- **Visuals:** blur thumbnails until tapped; dim viewed posts.
- **Fast-scroll throttling and memory eviction:** suspend thumbnail fetching during fast scrolling; evict off-screen images to prevent out-of-memory crashes.

## Phase 4: Viewer & Playback QoL
- **Zoom and aspect:** Fit/Fill/1:1 toggle; zoom to the tap point.
- **Playback:** video speed (1×/1.5×/2×); vertical comic mode (stacked images).
- **Gestures:** swipe down to dismiss; edge swipes for brightness/volume; tap hides the UI.
- **Utilities:** long-press peek; quick blacklist from the info panel; Copy Image to clipboard.

## Phase 5: Downloads & Maintenance
- Batch download the current grid; Select All / Invert; Retry All.
- **Network and size warnings:** NWPathMonitor cellular warning before large downloads; "Skip downloads larger than X MB" setting.
- Duplicate prevention; export a batch as ZIP; per-site cache clearing.

## Phase 6: UI Polish
- Landscape support, square-thumbnail toggle, hide adapters without deleting, grid spacing slider (0–12 pt).
- Dismissible banners (X button and swipe up).

## Critical Fixes (added mid-Phase 7)
- **Hotlink bypass:** every thumbnail/media request carries the adapter's headers (Referer, User-Agent…).
- **Protocol sanitization:** `//` and `http://` media URLs are upgraded to https (non-local hosts, falling back to http if https fails).

## Phase 7: Zero-Config Auth & Capability Prober
- API auto-discovery from a root URL.
- Capability Report: public vs login required, guest limits (max tags, preview only), locked features.
- Zero-config auth prober: just ask for the key; try Bearer, X-Api-Key and ?api_key=; reveal a User ID field when the error asks for one.
- Theme-aware guided key retrieval in a WKWebView (theme CSS injection, key/user-ID scraping, auto-fill).
- Live tag-separator probe (_, space, -).
- Native settings and blacklist import with a review checklist.
- Conditional capabilities (voting, related tags, wikis, aliases).

## Phase 8: Custom Themes, Unified Favorites & Power User UI
- Custom themes via ColorPicker, applied to SwiftUI and WebView CSS.
- Dual-save favorites (local plus account sync), a unified grid with site filter chips and search, cloud/phone icons, sync prompt on login.
- Tag category colors; prefer lighter formats; copy hash/MD5; undo toast for deletions; viewer background cycling; auto-hide system UI; copy URL/ID from the grid.
- Siri/Shortcuts via AppIntents.

## Phase 9: Continuous Playback & Autoplay ✅
- Loop Current vs Auto-Advance: videos advance on completion, GIFs after one cycle, images on a timer; loop at the end of a feed.

## Phase 10: Long-Form & Gallery Reading ✅
- Multi-page galleries, ImageIO-downsampled tall images, vertical stacking, "1 / 24" page indicator.

## Phase 11: Reader Ergonomics & Customization ✅
- RTL mode; tap-to-turn zones; orientation lock; Battery Saver; cache expiration; customizable viewer toolbar; swipe to switch sites.

## Phase 12: Ultimate Workflow QoL ✅
- Clipboard link detection.
- Reverse image search: configurable native and inline-web engines.
- Dominant-color background; data saver (low-res first); swipe-to-blacklist; mute uploader.

## Phase 13: Premium Privacy, Management, and Shortcuts ✅
- Decoy vault; storage breakdown chart; long-press tag actions; Wi-Fi-only media; database backup/restore; iPad split screen.

## Phase 14: iOS System Integration
- Share Extension; Picture-in-Picture; Random Favorite widget; audio mixing; EXIF viewer; floating scroll-to-top button.

## Phase 15: Advanced Data, Layouts, and Workflows
- iCloud sync; masonry grid; Read Later queue; visual query builder; download swipe actions; tag translation.

## Phase 16: Advanced Frameworks & Customization
- Vision smart thumbnails; smart collections; global autocomplete; gesture remapping; media editor (trim/crop); external display.

## Phase 17: Machine Learning, Background Tasks, and Advanced Reading
- OCR; feature-print near-duplicate detection; double-page landscape; saved-search watch notifications; video frame grabber; debug console.

## Phase 18: Sharing, AI Filtering, and System Shortcuts
- Adapter QR share/scan; on-device content blur; text-to-speech; Live Activities; deep links; image upscaling.

## Phase 19: Edge-Case Media & Format Handling
- ZIP frame animations (`zipExtensions`); HTML interception; HLS (.m3u8); animated WebP/APNG; case-insensitive extensions; zero-byte detection.

## Testing Matrix
Against the mock server:
- Pre-Phase fixes (URL sanitization, Done button, empty arrays)
- WebM audio
- Merged Search
- Gallery mode
- RTL swiping
- Cellular/size warnings
- Remaining Auto-Configure rows from last session (Site B, Demo Secure, broken URL, HTML URL, Site C low-confidence)
- Forced 422/429 error parsing

Docs: README.md, DECISIONS.md, BLOCKERS.md.
