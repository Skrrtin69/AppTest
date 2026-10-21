# Blockers

No flow is blocked. Every flow in the spec was driven on the device (iPhone 13, iOS 16.2, roothide) through the iOS MCP and passed. Two of them pass only with a workaround, and one couldn't be fully confirmed by automation:

## 1. Background URLSession downloads can't hand files to the app on this device
- **Symptom:** a background-session download finishes, but `didFinishDownloadingTo` can't move *or* copy the temp file ("you don't have permission").
- **Cause (observed):** under this TrollStore/roothide install, the system download service stores the finished file where the app's sandbox may not read it.
- **Resolution:** on the first permission error the app records that background mode is unsupported, switches to a regular session, and re-queues everything in flight. Verified on device: all queued items then completed. Background transfers stay enabled on devices where they work.
- **Remaining limitation:** on this device, downloads pause while the app is suspended and resume when it's reopened (also verified, including after killing the app).

## 2. WebM doesn't play in WebKit on iOS 16.2
- **Symptom:** `<video>` with a WebM source fires `error`; `canPlayType('video/webm')` is empty. The private WebKit feature flags for WebM aren't present on 16.2.
- **Resolution:** bundled ogv.js (WebAssembly VP8/VP9 decoder), served by the local server. Verified on device: both the VP8 and VP9 demo clips play and loop.

## 3. Not verifiable by automation
- **Haptics:** implemented behind the two toggles. Automation can't detect vibration.
- **Face ID:** the permission prompt and unlock were exercised. Face ID succeeded because someone was in front of the phone; a failed scan wasn't simulated (the passcode pad stays available as the fallback).

## 4. Not verifiable by automation (Phases 1–8)
- **WebM sound:** the web player reports sound on, and the toggle works. The tester can't hear the phone, so please listen once.
- **Cellular download warning:** the phone was on Wi-Fi during testing.
- **Landscape grid reflow:** the testing tool can't rotate the phone.
- **Siri / Shortcuts:** the intent builds; running it needs Siri or the Shortcuts app.

## 5. Dropped on purpose
- iCloud sync: needs real Apple signing and an iCloud container, which a fakesigned TrollStore app doesn't have. Use Settings › Data backups instead.
- Automatic API discovery, capability probing, automatic key-location testing, scraping keys or results from web pages, and CAPTCHA-backed web search engines.


## 6. Not verifiable by automation (Phases 12–13)
- **Wi-Fi-only media and "Data Saver: On mobile data":** the test phone is on Wi-Fi. "Data Saver: Always" was tested and uses the same code path.
- **iPad Split View:** there's no iPad to test on. The settings and layout rules are in place.
- **Random Favorite widget:** adding a widget changes the Home Screen layout, so the tester didn't do it. The app writes the widget's pictures and list (checked on the device: 4 thumbnails + feed.json); please add the widget once to see it.
- **Play alongside other audio:** whether two sounds mix can't be heard by automation.

## 7. Phase 16: separate picture on an external display
- Giving a connected TV its own scene requires the app delegate to supply scene configurations. In this SwiftUI app, that turned the phone's own window black on launch (two approaches tried, both reverted).
- iOS mirrors the phone to an external screen instead. A future attempt would need a UIKit scene manifest for the app window.

## 8. Not verifiable by automation (Phase 17)
- **Background refresh timing:** iOS decides when background refresh runs. The same check was verified by running it from the debug console (9 new posts found on the demo "rotating" search, with the "9 new" badge shown).

## 9. Phases 18–20
- No blockers. HLS was verified with a short local stream (demo Formats site, post u5). Real HLS servers may need the adapter's headers, which are passed to AVPlayer.
- Pools on adapters created before Phase 20 need the pool fields added by hand (Field Guide › Pools and archives). Only new installs get them on the built-in Demo Site A.

## 10. Reverse search against the real service
- The upload fix was tested on the demo engine, using an address shaped like the real one (`?output_type=2&api_key={api_key}&url={url}`, upload mode): a picture, an MP4, a WebM-only video and a ZIP animation, plus the cleaned error message. It wasn't run against the real service, to avoid sending demo pictures with the owner's key; one search from the app will confirm it.

## 11. Reverse search: opening matches natively and the dead-link banner
- **Fixed:** the demo server answered every `/a/view/<n>` (and `/b/view/<n>`) source page with 200, even for posts that don't exist. Because of that, the dead-link check thought the deleted demo post (999) was still there and never showed "Source deleted. Showing cached preview." Pages for posts that don't exist now answer 404, the way a deleted page does on a real site.
- **Routing:** a match link routes to one of your sites when its host matches the site's address or media address. A subdomain of either (for example `img.<site>`) now matches too. Each decision is written to the Debug Console under "Reverse": which site and post was picked, or that the link isn't on your sites and whether its page is gone. A link only opens in the app when the matching site is in your adapter list and switched on. Otherwise you get the preview, with the banner if the page is gone.
- **Dead-link checks:** a site match whose post can't be fetched (deleted, or no file) shows the banner. For other links, a page that answers 404/410, times out, or whose host no longer exists shows the banner too.

## 12. Smart address resolver (Auto-Configure)
- The demo server's root now has a webpage at `/index.php`, nothing at `/posts.json` and JSON at `/api/v1/posts`. Pasting `http://127.0.0.1:8765` therefore goes through all three steps: webpage → skip, 404 → skip, JSON → use. Verified in the app: `http://127.0.0.1:8765` resolved to `/api/v1/posts?tags={tags}&page={page}` and was configured with high confidence. `http://127.0.0.1:9` (nothing listening) showed the "Couldn't automatically resolve the API address…" message.

## 13. Log in to find my key
- **Tested end to end on the phone with the demo Vault site:**
  1. Analyze showed "Requires Authentication" with the API key fields.
  2. Log in to find my key opened the themed page.
  3. After logging in (demo/demo), the account page gave one key plus user ID 4821, with the parameter names. The session code was ignored. The form filled in and the re-analysis succeeded ("searching worked with your login").
  4. On Developer settings, the picker showed "Found next to 'API Key'" and "Found next to 'Secret'". Picking the first filled the form and analyzed again.
- **Untested:** the "no key on this page" message; the login form has no key, but that message was never seen on screen. Real sites lay out account pages in many ways. If a key isn't found, the page probably labels it with a word not in the list ("API Key", "API Token", "Secret", "Credentials", "Access Token/Key"). Type the key in by hand, or report the label so it can be added.

## 14. Connection wizard
- **Fixed:** the first device run of `127.0.0.1:8765` changed it to `https://127.0.0.1:8765` and hung on "Analyzing". The demo server only speaks http, so each of the seven paths waited for the full timeout plus retries. Local addresses now use http, and probes take at most 5 seconds with no retries. On the phone, `127.0.0.1:8765` resolved to `http://127.0.0.1:8765/api/v1/posts?tags={tags}&page={page}` in about a second.
- **Not yet run on the phone:**
  - the background auth tester (Demo Vault needs key + user ID, so the 4th way; Demo Header Key accepts only X-Api-Key, so the 3rd);
  - the "Key rejected" hint;
  - the manual fallback after Find Key on Page finds nothing;
  - the https→http fallback for a non-local site.

  A successful test saves an adapter, so running it adds demo adapters to the list.

## 15. Key reader: combined `&api_key=…&user_id=…`
- **Fixed:** on a live site, the key sat in a text box as `&api_key=…&user_id=…`. The reader only looked for `name=value` in the page's visible text, and text-box contents aren't part of that, so it reported no key. It also needed the value to start right after `?`, `&` or a space. Now `name=value` is read anywhere: page text, every text box, and highlighted text. The value runs to the next `&`, space or quote, so a combined string fills both the key and the user ID.
- **Highlighted text is read first:** text highlighted on the page or inside a box is parsed before the rest of the page. A bare highlighted code counts as the key.
- **Not run on the phone yet:** the demo Vault now has an "API credentials" page (`/v/combined`) with exactly that combined box. Running it through Test Connection saves a demo adapter.

## 16. Connection wizard: device results
- **Passed on the phone:**
  1. A wrong key on Demo Vault gave "Key rejected…", listing the three ways tried. No user ID was given, so the 4th wasn't tried.
  2. Find Key on Page on the login page (no key there) closed the page and showed "Key not found", the help text, "Take me to the settings page" and the key fields.
  3. That button reopened the site. After logging in, the API credentials page had `&api_key=…&user_id=…` in one box. Find Key on Page filled both fields, and Test Connection ran by itself and connected on the 4th way: "Connected (api_key= and user_id= in the address). Added 127.0.0.1 V." The test adapter was deleted afterwards.
- **Not run:** the X-Api-Key-only demo site (Demo Header Key).
- **Cosmetic:** the "key.slash" icon next to "Key not found" doesn't show on this iOS version.
- **Open question from the owner's own test:** a real site's bare address ended at "Check this address". Its index.php API may answer without JSON (for example a plain-text "missing authentication" message), which the resolver skips like any webpage. This hasn't been looked into yet.

## 17. Resolver: plain-text "Missing authentication" answers
- **Fixed:** the owner's live site answers its legacy API with plain text "Missing authentication…" and 200 OK. The resolver treated that like a webpage and skipped the path, ending at "Check this address". A short non-JSON answer containing an auth phrase now stops the resolver at that address and shows Requires Authentication. Probes keep the 5-second limit.
- **Verified on the phone:** the demo `/legacy` board answers its API that way (plain text, 200). Typing `127.0.0.1:8765/legacy` and tapping Analyze stopped at `http://127.0.0.1:8765/legacy/index.php?page=dapi&s=post&q=index&json=1&tags={tags}&pid={page}` with the Requires Authentication banner and "Log in to find my key". The demo board accepts the Vault key and user ID, so the rest of the flow can be run there too; that would save a demo adapter, so it wasn't run.

## 18. Tag post counts
- **Verified on the phone against the demo server:**
  - Auto-Configure set `tagCountPath: post_count` (high confidence).
  - Typing "bl" showed `blue (8)`, `deep_blue (8)` and a dimmed `bl_unused (0)`.
  - Tag Info on "red" showed "Tag: red, Posts: 7, Category: Color".
  - The demo adapter was deleted afterwards.
- **Owner's Danbooru adapter:** Tag Info said "black_hair" isn't listed. The adapter's `autocompletePath` is `tags.json?q={query}`, which that site ignores (it returns its newest tags). Change it to `tags.json?search[name_matches]={query}*&search[order]=count` in the adapter's editor, or run Auto-Configure again, which now rejects the old address. The owner's adapter was not changed.

## 19. Gestures, web video, Cloudflare: device results
- **Passed on the phone:**
  - **Cloudflare demo (`/cf`):** Analyze showed "This site is protected by Cloudflare. Tap to verify." (no Requires Authentication). Tapping it opened the check, and "Verify you are human" set the cookie. The app said "Verified. Trying the site again…" and the analysis succeeded.
  - **Key-header demo (`/hk`):** Test Connection with the key gave "Connected (Authorization: Key)". The test adapter was deleted afterwards.
  - **Volume swipe:** two downward swipes of 84 pt (10% of the screen) took the volume from 0.175 to 0.100 to 0.000. The first upward test was thrown off by an accidental button press. The volume was put back to 0.249.
  - **Side buttons right after a swipe:** volume up gave 0.311, then down gave 0.249, so the side buttons work again.
  - **Off switch:** with Enable Volume/Brightness Swipes off, an edge swipe left the volume unchanged. The switch was turned back on.
- **Not checked on the phone:**
  - Start videos muted (the switch exists and the players read it);
  - the web player's spinner and Retry, and the pre-warm;
  - 2 MB range streaming (needs a WebM from a real site);
  - the older suggestion addresses, the gallery-style endpoints and the automatic `*` for name_matches.

  The two new switches are in Settings › Appearance, next to "Autoplay videos in viewer".

## 20. Cloudflare check on live sites
- **Fixed:**
  - The check page opened the API address (for example `/api/galleries/search…`), so a real site showed its 404 page instead of the check. It now opens only `scheme://host/`.
  - It closed as soon as any cf_clearance cookie existed. An old pass therefore closed it before the user could do anything, and on first open the cookie store can read as empty until a page loads. Now it records the passes present once the first page has loaded, and closes only for a new one. Error pages never close it, and **Done** closes it on request.
- **Verified on the phone with the demo site:**
  - The check opened `http://127.0.0.1:8765/` (the root).
  - It stayed open for 8 seconds even though an old demo pass was stored, and stayed open on the 403 check page.
  - "Verify you are human" set a new pass, and the sheet closed on its own: "Verified. Trying the site again…", then a successful analysis.
  - The demo pass now changes on every launch so this can be repeated.
- **Settings:** Autoplay, Start videos muted and Enable Volume/Brightness Swipes are now in a new **Reading & Viewer** section (checked on the phone).

## 21. False Cloudflare prompt; legacy tag counts
- **Real trace (the owner's gallery site, captured on the phone by the new `[Probe]` lines in the Debug Console):**
  - Old API shapes (`/api/v1/posts`, `/api/posts`, `/api/galleries/search`): **403 `text/plain`**, body `Use new API https://…/api/v2/docs`, `Server: cloudflare` and `cf-ray`, **no `cf-mitigated`**.
  - Other shapes: 404 HTML pages with the same Cloudflare headers.
  - `/api/v2/search?query=…`: 200 JSON, no login.
  - **Cause:** every answer from a site behind Cloudflare carries those headers. The check counted any non-JSON 403 with them as a challenge. The resolver stopped at the first such answer, so re-analyzing after the check hit the same path and showed the same prompt.
- **Fixed:**
  - Cloudflare is reported only for `cf-mitigated: challenge` or a 403/503/429 page with Cloudflare's own check-page markup.
  - A 403 counts as a login problem only when it says so, is JSON, or is empty. Other 403s are ordinary errors, and the next shape is tried.
  - `/api/v2/search?query={tags}&page={page}` and `/api/v2/posts?tags={tags}&page={page}` were added to the shapes tried.
- **Verified on the phone:** Analyze on the real site resolved to `/api/v2/search`, public, with no Cloudflare card. The mock `/mv` (same answers) did the same.
- **Still open for that site:** its thumbnails are relative paths served from a separate image host. The media base address is marked low confidence and needs setting before images load.
- **Legacy tag counts:** the probe sent `q=` to `index.php?page=autocomplete2`, which answers `[]` on a real board; it needs `term=`. The other style of board redirects `public/autocomplete.php` and puts the count only in the label (`blush (3922720)`). Both are now detected. The tag name is read from `value` before `label`, and counts are parsed from the label.
  - Verified on the phone: mocks `/lb1` (autocomplete2, counts as strings) and `/lb2` (302 to JSON sent as text/html, counts in labels) both showed `blue, 8 posts` in the search bar. Both test adapters were deleted.
  - The owner's saved Gelbooru and Rule34 adapters have **no suggestions address**. They need Auto-Configure re-run, or the address added in Edit, to show counts. They were not changed.

## 22. Web video timeout and pipeline
- **Done:** a launch speed test sets the timeout (15/30/60 s). The native "Loading video..." overlay is shown until `canplay`. A Retry / Open in Safari card appears on timeout or error. ogv.js modules are loaded before the stream starts. The proxy streams 206 answers.
- **Verified on the phone, live videos from the owner's Danbooru adapter (`filetype:webm`):**
  - The speed test measured 21.9 Mbps, so the timeout is 15 s.
  - A 19 MB WebM was playing in ogv.js 1.4 s after the tap.
  - Range pieces: the site's CDN answers 206.
- **Not seen on the phone:** the timeout card itself. Every live video started well within 15 s.

## 23. WebM decoding speed: threads, SIMD, sniffing, VLCKit
- **Verified on the phone (iOS 16.2), same live 21.7 MB 1080×1920 VP9 WebM, 30 fps:**

  | Player | Start | Decoding | Keeps up |
  |---|---|---|---|
  | ogv.js, 1 thread | metadata 0.4 s after page load | 21–32 ms/frame | yes (1.00×), little headroom |
  | ogv.js, 4 threads | metadata 0.6 s after page load | 14–19 ms/frame (8 late frames while threads start) | yes (1.00×) |
  | VLCKit | playing 0.2 s after opening | native | yes; pause, play and time (0:09 / 0:56) work |

  - The page reported `isolated=true SharedArrayBuffer=true simd=false cores=4`. Sniffing read the file as `Matroska/WebM, video V_VP9`.
  - The proxy delivers 1 MB in 0.2–0.4 s. The first streaming version, a byte-by-byte loop, managed only 0.3 MB/s; this was found and fixed during testing.
  - My first stats wrongly showed stalls: ogv's `resetPlaybackStats()` also zeroes its frame counter. The stats now report per-window frames and a real-time ratio.
- **Not testable here:** SIMD (needs iOS 16.4+). An MP4 named .webm and H.264-in-Matroska weren't found among live posts, so those two sniffing branches are untested on the phone.
- **State left on the phone:** VLCKit off (default), single-thread test switch off. At the owner's request, MediaDeck's app passcode (and decoy passcode) was turned off so reinstalls no longer stop at the lock screen.

## 24. Optimized build, VLCKit default
- `SWIFT_OPTIMIZATION_LEVEL` changed from `-Onone` to `-O` for all three targets. "Use VLCKit for Video" now defaults to on.
- **Smoke test of the optimized build on the phone:**
  - It launched and browsed Danbooru.
  - A fast-scrolled `rating:g` grid loaded its thumbnails, and an image opened in the viewer.
  - A live 19 MB WebM played in VLCKit.
- The phone had a stored "off" from the speed tests, so it was switched on in Settings by hand. The new default only applies when nothing is stored.
- **Not measured:** before/after timings for UI, parsing or image loading. The change is standard; the gains weren't benchmarked.

## 25. VLCKit tap, background and layout
- **Verified on the phone with the live 56 s 1080x1920 WebM:**
  - **Tap:** a tap hid all the controls while the video kept playing; a second tap showed them again, still playing. Pause and Play on the bar worked.
  - **Layout:** the bar (Pause, scrubber, time) is drawn above the bottom toolbar and the home indicator.
  - **Background while playing:** left at 0:13 for 15 s; the log shows "Background: stopped at 14569 ms (was playing)" and "Foreground: reopened at 14569 ms, playing". The time went 0:16, then 0:20, with no error.
  - **Background while paused:** left at 0:09; it came back paused, showing the frame at 0:10 (VLC resumes at the nearest keyframe), and Play continued from there.
- **Found during testing:** the controls had been invisible under VLC's video since VLCKit was added; scenePhase never reached the viewer; and a Play/reopen race. All three are fixed.
- **Not changed:** the web player (ogv.js) still pauses on tap, because it has no control bar. It's only used when VLCKit is off.

## 26. Multi-tag searches failing on the legacy board ("path 'post' … nothing was found")
- **Real trace from the phone (owner's Gelbooru adapter):**
  - Request: `index.php?page=dapi&s=post&q=index&json=1&tags=the_elder_scrolls%20animated&pid=1&api_key=•••&user_id=•••` returned 200 with 51 bytes.
  - Answer: `{"@attributes":{"limit":100,"count":86,"offset":0}}`. 86 posts match, but there was no `post` list.
- **Root cause:** the adapter had "First page number" = 1 (Auto-Configure always set 1), while the API's `pid` counts from 0. Every first page was really the second page (items 100–199).
  - Searches with more than 100 results looked fine, but skipped the newest 100 posts. For example, single-tag `the_elder_scrolls` loaded pid 1, 2, 3 and never pid 0.
  - Searches with 100 or fewer results (common with two or more tags) got an empty second page, and the API leaves `post` out when a page is empty.
- **Ruled out by the trace:**
  - Tag joining: tags are sent as `%20`, which the API accepts.
  - Cross-site suggestions: the request held exactly the two typed tags, both valid on this site. Note that the suggestion list does merge this site's autocomplete with tags known from history and favorites on every site.
- **Fixed:** the page base is detected in Auto-Configure; a list-less answer means 0 results; an empty first page with a match count gets a clear message. All of these are logged.
- **Owner's adapter:** with the owner's permission, Gelbooru's "First page number" was changed from 1 to 0. Verified: the same search now sends `pid=0` and gets 89,971 bytes of posts. Scrolling past the end gets the empty `pid=1` page, which now ends the list without an error.
- **Not tested on the phone:** the Auto-Configure page-base probe (the live board needs the owner's key in the wizard).

## 27. Page-base auto-detection and Reverse Search Image
- **Pagination, verified on the phone:** demo legacy board 1 now behaves like the real board: `pid` from 0, the list under `post`, and no `post` key on an empty page. Auto-Configure on `127.0.0.1:8765/lb1` with tag `blue` (8 posts) proposed "First page number: 0. High confidence. Page 1 came back without results and page 0 had 8 posts, so pages are counted from 0." Nothing was saved.
- **Reverse Search Image, verified on the phone (demo engine only; the owner's SauceNAO engine wasn't used):**
  - The system photo picker opened and returned a screenshot from the library.
  - The site sheet listed the enabled sites. With Check All, all 5 matches showed in the grid with similarity and site.
  - With only the demo site, the screen showed "3 of 5 matches are on the chosen sites".
  - Tapping the 96% match opened the real post through the adapter (Info: Site 127.0.0.1 A, ID 10).
  - Switching one site off from Check All left the others on.
- **Found during testing:** the demo server didn't understand `id:N`, so opening a match on a demo adapter without a single-post address failed ("Post 10 wasn't found"). It now does, like real boards.
- **Cleaned up:** the temporary demo adapter and the demo reverse engine were deleted. The owner's adapters (Danbooru Donmai, Gelbooru) and the SauceNAO engine are unchanged.
- **Not tested:** a real engine with a library photo (to save the owner's quota), and the Browse menu entry, which wasn't added: the entry point is Settings › Tools.

## 28. Reverse Search Image returned to "Choose Photo" without the site sheet
- **Reproduced on the phone** with the owner's newest library item: the picker closed, the screen went back to "Choose Photo", and there was no error. The live system log showed the picker registering the item with a `(null)` UTI.
- **New logging (`[PhotoPick]`):** `picked: types org.webmproject.webp, UIImage loadable: false`.
- **Root cause:** the item is a WebP. On iOS 16.2, NSItemProvider can't load a WebP as a UIImage. The old code treated that as "nothing picked" and returned silently. The sheet was also opened on a fixed 0.5 s timer, which could race the picker's dismissal.
- **Fix:** the photo is read from its data and decoded with ImageIO (which handles WebP, HEIC and very large photos), with the UIImage loader as a fallback. Errors are shown on screen. The site sheet opens after both the photo and the picker's dismissal are done, and every step is logged.
- **Verified on the phone with the same WebP:** "read 160992 B of org.webmproject.webp → 1920x1080", then the picker closed (before the photo was ready), then "showing Sites to Check". A demo-engine search then uploaded a 196 KB JPEG and returned 5 matches.
- The demo engine was deleted afterwards; the owner's SauceNAO engine was never used.

## 29. HTTP 403 from the reverse engine on photo search
- **Reported by the owner:** the photo search on their SauceNAO engine answered HTTP 403.
- **Change:**
  - Every reverse-engine request now carries a Safari User-Agent for the phone's iOS version (e.g. `… iPhone OS 16_2 … Version/16.2 Mobile/15E148 Safari/604.1`), unless the request already has one. Redirected uploads keep it.
  - Any non-2xx answer is logged as `[Reverse]` with the status, content type, whether Cloudflare answered (cf-ray / Server), cf-mitigated, and the first 500 characters of the body. The owner's API key is masked if it appears.
- **Not tested here:** the engine itself, to save the owner's quota. The owner will test, and the `[Reverse]` line will show whether a remaining 403 is a Cloudflare page or the engine's own message.
