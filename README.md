# MediaDeck

A config-driven media browser for jailbroken / TrollStore iPhones. It browses images, GIFs and short videos from "sites" described entirely in a JSON file (`adapters.json`). It knows nothing about any particular site. On first launch it works fully offline against a small demo server built into the app.

- iOS 15+ (tested on iOS 16.2, iPhone 13, roothide jailbreak with TrollStore-style install)
- SwiftUI app with UIKit where needed (video, zoom, document picker)
- Built in the cloud on GitHub Actions (no Mac needed) as an **unsigned, fakesigned IPA**

---

## Install

1. Open the repository on GitHub → **Actions** → latest green **Build unsigned IPA** run.
2. Download the **MediaDeck-ipa** artifact (a zip containing `MediaDeck.ipa`).
3. Install `MediaDeck.ipa` with TrollStore (or any installer that accepts IPAs on a jailbroken device).
   - Fallback: the **MediaDeck-deb** artifact contains a rootless `.deb`; install it with your package manager.

## Build it yourself

Every push to `main` builds automatically. To build by hand on a Mac:

```sh
brew install xcodegen ldid
xcodegen generate          # creates MediaDeck.xcodeproj from project.yml
bash scripts/build_ipa.sh  # → build/MediaDeck.ipa (unsigned, fakesigned with Support/MediaDeck.entitlements)
bash scripts/build_deb.sh  # optional → build/mediadeck_<version>_iphoneos-arm64.deb
```

`scripts/make_media.sh` regenerates the demo video clips (needs ffmpeg). The clips are already committed.

---

## Features

**Browsing**
- Multiple sites from `adapters.json`; enable/disable and drag-to-reorder them in Settings.
- Site switcher (globe button).
- Tag search: space-separated tags; `-tag` excludes a tag.
- Search history (persistent, tap to re-run) and saved searches (bookmark button).
- Several searches open at once as tabs, each keeping its own scroll position and pages.
- Infinite scroll with a loading footer; stops at the last page.
- Sort and rating menus (choices come from the adapter).
- Pull to refresh.

**Viewing**
- Grid with 2–5 columns; square or original-shape thumbnails; GIFs animate in the grid.
- Full-screen viewer: pinch or double-tap to zoom, drag to pan, swipe between posts. The two posts on each side are preloaded.
- Videos loop; tap to play/pause; scrubber. See *Video formats* below.
- Slideshow with a 2–30 second interval.
- Info panel: dimensions, tappable tags (each opens a new search tab), source link (copy/open), extra info from the adapter.

**Downloads and library**
- One-tap download in the viewer.
- Multi-select batch download: long-press a thumbnail → **Select**, then tap more.
- Download queue with per-item progress, pause/resume, retry and cancel.
- Original or preview quality.
- File name and folder templates: `{site}` `{id}` `{index}` `{type}` `{date}`.
- Library grid with a site filter and search (file name, tags, site), plus bulk delete.
- Export to Photos or to the Files app.
- Downloads survive an app restart and resume automatically.

**Accounts and security**
- One account per adapter (username, password, API key), stored in the iOS Keychain.
- Login status for each adapter, and automatic re-login.
- App passcode (4–6 digits) with optional Face ID / Touch ID; locks when you leave the app, with an adjustable grace period. A privacy cover hides content in the app switcher.

**Organizing**
- Local favorites and named collections, independent of any server.
- Tag blacklist: hidden everywhere (grids, favorites, collections).

**Settings**
- Themes: System, Light, Dark, AMOLED black.
- Haptics on/off.
- Cache size, cache limit and Clear Cache.
- Sliders for simultaneous thumbnail loads and simultaneous downloads.
- Per-adapter proxy, User-Agent, extra headers and request rate (requests per second).
- Clear search history, delete downloads, reset settings.
- Import/export settings and adapters through the Files app.
- Version number and "Check for Updates".

**Adapters screen** (Settings → Sites & Adapters)
- An Add/Edit form with every field, a plain-English explanation and an example under each, and live checking of web addresses.
- **Field Mapper:** paste a JSON answer (or have the app fetch one), tap **Analyze**, and see every path with its value. Each row has **Copy** and **Use as…**, which fills the right field for you.
- **Test adapter:** runs a real search and shows the first 5 results with thumbnails. **Check rate limit** shows the request rate working.
- Import/export `adapters.json` with instructions, plus a Field Guide that explains every field.

---

## Video formats: which player plays what

The app checks each video at the moment it is opened:

| Format | Player | How |
|---|---|---|
| MP4 / MOV / M4V (H.264, HEVC) | **Native player (AVPlayer)** | AVFoundation says the file is playable, so it plays in a custom `AVPlayerLayer` view with loop, tap-to-pause and a scrubber. |
| WebM (VP8 or VP9) | **Web player (WKWebView) · ogv.js (WebAssembly)** | AVFoundation refuses WebM, so the app opens a small player page served by its own local server. The page first tries WebKit's `<video>`. iOS 16.2's WebKit can't play WebM, so it then uses the bundled **ogv.js** decoder, which decodes VP8/VP9 in WebAssembly. |
| Anything else AVPlayer refuses | Web player | Same route. If neither WebKit nor ogv.js can play it, you get a clear message instead of a black screen. |

A small label in the viewer always says which player is in use.

Notes and limits:
- WebM decoding in WebAssembly uses the CPU. It's fine for short clips but heavier than native playback for long, high-resolution videos.
- Videos from your own sites are fetched through the app's local `/proxy`, so the decoder can read them even if the site sends no CORS headers.
- Photos can't store WebM. Exporting a WebM to Photos is skipped (with a message); export it to Files instead.

## Known limitations

- **Background downloads** use a background `URLSession` where the device allows it. On this test device (roothide/TrollStore) the system's download service saves finished files somewhere the app isn't allowed to read. The app notices the first time, switches to regular downloads automatically, and restarts anything in progress. Regular downloads stop if iOS suspends the app, but resume when you reopen it.
- **The demo server is deliberately slow for video downloads** (about 20 KB/s, only for the app's own downloader, never for playback), so you can see pause/resume/cancel working. Real sites aren't affected.
- The demo server only runs while the app is open. Its address is `127.0.0.1:8765`, or the next free port if 8765 is taken.
- Haptics are implemented and switchable, but automated testing can't feel vibration, so they were only checked in code.

---

## Adding a real site — step by step, no code

You never need to edit code. Everything about a site lives in one text file, `adapters.json`.

**Before you start:** you need the site's API address for searching (from the site's own API documentation or help pages), and, if it requires one, your login or API key.

1. **Export the file.** In MediaDeck: Settings → Sites & Adapters → **Export adapters.json to Files**. Save it somewhere you can find it, e.g. *On My iPhone*.
   (The app's own copy is always in Files → On My iPhone → **MediaDeck** → `adapters.json`. If you edit that one directly, the app reloads it automatically.)
2. **Open it in any text editor** (e.g. a free "text editor" app from the App Store, or Runestone). The file is a list of blocks between `{` and `}`, one per site.
3. **Copy a block.** Copy the whole `{ … }` block of *Demo Site A* and paste it after it. Put a comma between the two blocks: `},` then `{`.
4. **Fill in the basics** in your new block:
   - `"id"`: a short name without spaces, e.g. `"my-site"`.
   - `"displayName"`: the name you want to see.
   - `"baseURL"`: the start of the site's API address.
   - `"searchPath"`: the rest of the search address. Put `{tags}` where your search words go and `{page}` where the page number goes.
5. **Find the paths with the Field Mapper.** In MediaDeck, open Settings → Sites & Adapters → **Field Mapper**. Paste an answer from the site's search address (open the address in a browser, select all, copy), then tap **Analyze**. Every piece of information is listed with its *path*. Find:
   - the list of results → put its path in `"searchResultsPath"` (e.g. `"posts"`);
   - inside the first result, the ID, thumbnail address, full media address, file type and tags → put those paths in `"postIDPath"`, `"thumbnailURLPath"`, `"mediaURLPath"`, `"mediaTypePath"`, `"tagsPath"`. Leave out the beginning that points at the first result: if the mapper shows `posts[0].file_url`, write `file_url`.

   Tap **Copy** next to any path to paste it into your file.
   Even easier: tap **Add Adapter** in the app instead of editing the file, fill in the basics, open the Field Mapper from inside the form, and use **Use as…** on each row. The app fills in the fields and removes the `posts[0].` part for you.
6. **Pages:** if the site uses page numbers, keep `"paginationStyle": "pageNumber"`. If each answer contains a "next page" token, use `"cursor"` and set `"cursorPath"` to where that token is.
7. **Login (only if needed):** set `"requiresAuth": true` and `"authStyle"` to `"basic"` (username + password), `"apiKeyQuery"` or `"apiKeyHeader"` (with `"authParamName"`). Your actual password or key goes in the app, not the file: open the adapter → **Account**.
8. **Import the file back:** Sites & Adapters → **Import adapters.json from Files**. If something is wrong, the app tells you in plain words which adapter and which field.
9. **Test it:** tap **Edit** on your adapter → type a tag → **Test adapter**. You should see "Works!" and five thumbnails.

### Example: a complete adapter (uses only the built-in demo server)

This is the login-protected demo area. It is also available in the app under Add Adapter → *Fill in from an example… → Demo Secure*. To use it, add the account `demo` / `demo` under **Account**.

```json
{
  "id": "demo-secure",
  "displayName": "Demo Secure",
  "baseURL": "http://127.0.0.1:8765/a/secure",
  "searchPath": "posts.json?tags={tags}&page={page}&sort={sort}",
  "postPath": "post/{id}.json",
  "mediaBaseURL": "http://127.0.0.1:8765/",
  "requiresAuth": true,
  "rateLimitPerSecond": 4,
  "searchResultsPath": "posts",
  "postIDPath": "id",
  "thumbnailURLPath": "preview_url",
  "mediaURLPath": "file_url",
  "mediaTypePath": "file_ext",
  "tagsPath": "tags",
  "tagsNameKey": null,
  "sourceURLPath": "source",
  "videoExtensions": ["mp4", "webm", "mov", "m4v"],
  "gifExtensions": ["gif"],
  "authStyle": "basic",
  "authParamName": null,
  "paginationStyle": "pageNumber",
  "hasNextPagePath": "has_more",
  "cursorPath": null,
  "sampleURLPath": null,
  "postResultPath": null,
  "metadataPaths": {},
  "authCheckPath": "auth/check",
  "tagSeparator": "+",
  "firstPageIndex": 1,
  "sortOptions": ["newest", "oldest", "random"],
  "ratingOptions": [],
  "userAgent": null,
  "proxyHost": null,
  "proxyPort": null,
  "timeoutSeconds": 20,
  "headers": {}
}
```

`Resources/adapters.json` has two more complete examples. *Demo Site B* shows nested paths (`data.items`, `post.media.full`), tags stored as objects (`"tagsNameKey": "name"`), cursor pages and relative media addresses.

---

## Adding a reverse search engine

Settings › Tools › Reverse Search › Add Engine (or **Edit all as JSON**). The demo engine looks like this:

```json
{
  "id": "demo-reverse",
  "name": "Demo Reverse Search",
  "enabled": true,
  "mode": "upload",
  "requestURL": "http://127.0.0.1:8765/rs/search?api_key={api_key}",
  "uploadField": "file",
  "resultsPath": "results",
  "similarityPath": "header.similarity",
  "thumbnailPath": "header.thumbnail",
  "sourceURLPath": "data.urls[0]",
  "titlePath": "data.title",
  "minSimilarity": 0
}
```

- `mode`: `"url"` sends the picture's address in place of `{url}`; `"upload"` posts the file in the form field `uploadField`. Pictures that are only on this phone are always uploaded.
- `{api_key}` is filled from the key you type in the engine's form. Keys are stored in the Keychain, never in the JSON file.
- The paths work like adapter paths. `resultsPath` is the list of matches; the other paths are read inside each match.
- Use the engine's own JSON API. MediaDeck doesn't read web pages meant for browsers.

## Project layout

```
App/          entry point, boot sequence, overlay window (toasts + lock screen)
Core/         models & protocol, networking (client, rate limiter), cache, Core Data, Keychain, settings
Adapters/     AdapterConfig, GenericAdapter, dotted-path evaluator
Features/     Browse, Viewer, Media (players), Downloads, Library, Settings, Adapters, Auth
MockServer/   built-in demo server (NWListener), demo data, media generator, player routes
Resources/    adapters.json, demo clips, ogv.js player files, app icon
Support/      entitlements (Info.plist is generated)
scripts/      build_ipa.sh, build_deb.sh, make_media.sh
```

Third-party code: **ogv.js** 1.9.0 (MIT; includes libvpx, nestegg, libopus and libvorbis under their BSD-style licenses). The license files are in `Resources/Player/ogv/`.

See `DECISIONS.md` for design choices and `BLOCKERS.md` for open issues.

---

## Auto-Configure (replaces most manual Field Mapper steps)

Settings → Sites & Adapters → **Auto-configure from URL** (or the **Auto-configure from URL** button inside the adapter form, which fills that form in place).

1. Paste the site's search address with `{tags}` and `{page}` (or `{cursor}`) placeholders, and type a sample tag that has results. **Try a demo address** fills in demo examples.
2. Tap **Analyze**. MediaDeck downloads page 1, finds the list of results, looks at the first three, and proposes every field.
3. Each field shows a dot (green = sure, yellow = likely, red = check this) and one sentence saying exactly why it was chosen.
4. The preview shows the first 5 results built from the proposal; a broken result shows the failing field in red.
5. **Test** runs a real search, **Edit fields** opens the normal form, and **Save adapter** adds the site and opens it in Browse. Sites with red-dot fields get a red badge on their Browse tab that opens the form at those fields.
6. If the site needs a login, Analyze says so and asks you to choose the login style (it never guesses), then run Analyze again.

Failures are explained in plain English with one next step: bad address, unreachable server, HTTP error (with the server's text), a web page instead of an API, or no list found (with a button to the Field Mapper).

---

## What's new (Phases 1–12)

**Playback and errors**
- Videos that come in both MP4 and WebM play as MP4 (native, with sound). WebM-only videos play with sound in the web player; tap the speaker to mute/unmute.
- Errors show the site's own words ("You can search for at most 6 tags…", "Too many requests…"), or just "HTTP 429" when the site says nothing.
- Media requests carry the adapter's headers plus a Referer, so sites that block hotlinking work. Public `http://` media is upgraded to https (with a fallback), and a web page where a picture was expected says "Site blocked request or requires login."

**Searching**
- "Quoted words" are one tag; spaces inside become the adapter's `tagSpaceReplacement` (e.g. `_`).
- Tag suggestions while typing (adapter `autocompletePath`).
- Tag pills with ✕, a dice for random results, numbers-only searches open that post ID, Go to page…, tap the active tab to scroll up, and sort/rating remembered per site.
- **All Sites (merged)** searches every enabled site at once. Each thumbnail gets a small site badge, and one site failing doesn't stop the others.
- Optional blur-until-tapped and dimming of posts you've opened.

**Viewer**
- Fit / Fill / 1:1, double-tap zooms where you tap, 1× / 1.5× / 2× video speed, a vertical (comic) reading mode, and a black / white / checkerboard background.
- Swipe down to close; slide on the left edge for brightness and the right edge for volume. A tap hides all controls (and the home indicator).
- Long-press a thumbnail for a big preview; Copy Image, Copy ID, Copy MD5.
- Info panel: hold a tag to blacklist it. When the adapter has the addresses, it also shows related tags, tag descriptions and aliases, a vote button, and tag colors by category.

**Downloads and data**
- Download All Results, Select All / Invert, Retry All, and Download Anyway for files over your size limit.
- Asks before big downloads on mobile data, skips files that are already downloaded, exports a ZIP, and clears the cache for one site.
- Deleting from the Library or unfavoriting can be undone from the message that appears.

**Accounts**
- After logging in, MediaDeck offers to import the account's hidden tags and default sort/rating, as a checklist you review first.
- Sites can link their sign-up and API-key pages. They open inside the app, styled to match your theme. Log in yourself, highlight your key, tap **Copy Selection**, and paste it into the form.
- If a site wants a user ID next to the key, Auto-Configure notices from the site's own error and shows a User ID field.
- Favorites can also save to your account (adapter `favoritePath`). A cloud icon means saved to the account, a phone icon means only on this phone. After logging in, the app offers to upload phone-only favorites.

**Look**
- Custom themes: Settings › Theme › New Theme, with the iOS color picker for background, surface, text and accent. They apply to the whole app and to the site pages it opens.
- Landscape adds two grid columns, plus a grid spacing slider (0–12 pt).
- Messages can be dismissed with ✕ or a swipe up.

**Continuous playback (Phase 9)**
- The viewer's repeat button switches **Loop** (each post repeats) and **Auto-advance**. With auto-advance on, videos move on when they end, GIFs after one cycle, and still pictures after the slideshow interval. After the last post it goes back to the first.

**Galleries and long strips (Phase 10)**
- Posts with several pages (albums, comics) show a stack badge with the page count in the grid. They open as a scrolling reader with a **3 / 24** counter, plus buttons that jump to the first or last page.
- Very tall pictures are decoded at screen width, not shrunk by their height, so they stay sharp without using too much memory.
- Vertical reading mode shows every page of every gallery one after another.
- Auto-Configure notices a list of page addresses in each result and fills in `galleryPath` / `galleryURLKey`.

**Reading comfort (Phase 11)**
- **Right-to-left** page order for manga: swipe right for the next post.
- **Tap the edges to turn pages:** the outer third of a picture goes back or forward (mirrored in right-to-left mode), and the middle shows or hides the controls.
- **Viewer toolbar:** Settings › Reading › Viewer toolbar picks which buttons sit in the bar. The others are in the bar's ⋯ (sliders) menu, so nothing is lost.
- **Battery Saver** (Settings › Battery): Off, With Low Power Mode (default), or Always on. It stops GIF animation in grids, doesn't start videos by itself, shows the lighter file when the site has one, and doesn't preload neighbouring posts.
- **Cache expiry:** Settings › Cache can delete cached files you haven't opened in 7, 14 or 30 days (default: never).
- **Switch sites by swiping** the site name at the top of Browse (the small arrows show it's swipeable).
- **Rotation lock** for the viewer, in Settings › Reading and in the viewer's ⋯ menu.

**Workflow (Phase 12)**
- **Reverse search:** viewer ⋯ › Reverse Search finds where a picture comes from. Engines are described in JSON, just like adapters (Settings › Tools › Reverse Search, or `reverse_search.json` in Files). See "Adding a reverse search engine" below. A match on one of your sites opens right in MediaDeck.
- **Copied links:** copy a link to a post or search on one of your sites, come back to MediaDeck, and tap **Open** on the message.
- **Picture-color background:** the viewer's background button now also cycles to a dark version of each picture's main color.
- **Data Saver** (Settings › Battery and data): pictures open in their smaller version first, with a **Load Full Resolution** button. Choose Off, On mobile data, or Always.
- **Swipe up on a post** (or ⋯ › Hide Posts Like This) to hide every post with one of its tags, or mute its uploader. Each one can be undone from the message.
- **Mute uploaders:** the Info panel shows the uploader with a Mute button when the adapter maps one. Add `"uploader": "<path>"` to `metadataPaths`; Auto-Configure does this when it sees a field like `uploader` or `author`. Muted uploaders appear in the Tag Blacklist as `uploader:name`.

**Shortcuts:** "Search in MediaDeck" asks for tags and opens the app on that search (iOS 16+).

### New adapters.json fields (all optional)
`alternateMediaURLPaths`, `tagSpaceReplacement`, `autocompletePath`, `autocompleteResultsPath`, `autocompleteNameKey`, `randomTag`, `relatedTagsPath`, `wikiPath`, `tagAliasesPath`, `votePath`, `accountSettingsPath`, `registerURL`, `authUserParamName`, `apiKeyPageURL`, `favoritePath`, `tagCategoryKey`, `galleryPath`, `galleryURLKey`, and the `bearer` login style. `metadataPaths` can also hold an `uploader` entry.

Each is explained in Settings › Sites & Adapters › Field Guide. Features whose field is empty don't appear in the app.
