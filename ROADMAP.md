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

## Phase 7: Account Sync & Adapter Intelligence
- **API auto-discovery:** paste a root URL; probe common paths, read HTML hints and headers to find the JSON endpoint.
- **Guest-limits detection:** notice when a site restricts features without login, and prompt to log in.
- **Native settings and blacklist import:** after login, fetch native settings; review a native blacklist in a checklist before merging.
- **Conditional capabilities:** detect supported features (voting, related tags, wikis, aliases) and only show those controls.
- **Quick registration:** in-app WKWebView to register an account.

## Phase 8: Power User UI
- **Tag colors and formats:** color-code tag categories; prefer lighter formats (JPG/WebP) via a setting.
- **Utilities:** copy hash/MD5; undo toast for deletions; viewer background cycle (black/white/checkerboard); auto-hide system UI in fullscreen; copy URL/ID from the grid.
- **Siri/Shortcuts:** trigger searches through AppIntents.

## Phase 9: Continuous Playback & Autoplay
- **End-of-media behavior:** Loop Current vs Auto-Advance toggle in the viewer toolbar.
- Videos advance on completion, GIFs after one cycle, images on a timer; loop back to the start at the end of a feed.

## Phase 10: Long-Form & Gallery Reading
- Multi-page galleries (posts with arrays of images).
- Memory-efficient tall images (ImageIO downsampling).
- Vertical stacking for seamless reading; "1 / 24" page indicator.

## Phase 11: Reader Ergonomics & Customization
- RTL reading mode (inverted swipes and counters).
- Tap-to-turn zones.
- Orientation lock, Battery Saver mode, cache expiration (7/14/30 days/Never).
- Customizable viewer toolbar; quick site switching by swiping.

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
