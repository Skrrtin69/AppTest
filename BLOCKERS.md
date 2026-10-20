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
