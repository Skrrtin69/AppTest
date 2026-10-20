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
