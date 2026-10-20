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
  3. Find Key on Page before logging in found nothing.
  4. After logging in (demo/demo), the account page gave one key plus user ID 4821, with the parameter names. The session code was ignored. The form filled in and the re-analysis succeeded ("searching worked with your login").
  5. On Developer settings, the picker showed "Found next to 'API Key'" and "Found next to 'Secret'". Picking the first filled the form and analyzed again.
- **Untested:** real sites lay out account pages in many ways. If a key isn't found, the page probably labels it with a word not in the list ("API Key", "API Token", "Secret", "Credentials", "Access Token/Key"). Type the key in by hand, or report the label so it can be added.
