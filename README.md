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
- When a picture is uploaded, any `url={url}` part of the address is left out automatically, so one address works in both modes. Videos are searched by their first frame, and animations (GIF, WebP, APNG, ZIP) by their first frame; the raw video or archive is never sent.
- If the engine reports an error (for example a negative `header.status`), its message is shown as plain text.

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

**Just the site's address works too, even without `https://`.**
- **Adding the scheme:** type `example.org` and Auto-Configure adds `https://` for you. Local addresses (`127.0.0.1…`, `192.168.…`, `10.…`, `localhost`) get `http://`.
- **Finding the API:** with only a site's address, it tries seven common API shapes in order:
  - `/index.php?page=dapi&s=post&q=index&json=1&tags={tags}&pid={page}`
  - the same without `json=1`
  - `/posts.json?tags={tags}&page={page}`
  - `/api/v1/posts?tags={tags}&page={page}`
  - `/post.json?…`
  - `/post/index.json?…`
  - `/api/posts?…`

  It uses the first that answers with JSON (an XML answer is skipped, since adapters read JSON).
- **Fast probes:** each probe gets 5 seconds and no retries. When `https://` was only assumed and can't connect, the same path is tried over `http://` before moving on.
- **If nothing answers:** the field is filled with `…/posts.json?tags={tags}&page={page}`, and you see "Couldn't auto-resolve. Please check this default address."


**Logging in: Test Connection.** There is no login style to choose. Open **Login (optional)**, paste your API key (and a user ID if the site gave you one), and tap **Test Connection**. It also runs when you tap Analyze with a key filled in. MediaDeck quietly tries, in order:
1. `api_key=` in the address
2. `Authorization: Bearer <key>`
3. an `X-Api-Key` header
4. `api_key=` plus `user_id=` in the address

The first one the site accepts is kept: the adapter is saved, the wizard closes, and a message says how it connected. If the page reader saw different parameter names (for example `login=`), those are used instead. If every way is refused, you see: "Key rejected. Check if it requires a User ID alongside it, or if the key has expired." For sites with a username and password, switch on **The site uses a username and password**.

**If Find Key on Page finds nothing:** the web page closes and the key fields open with "We couldn't find your key automatically. You can find it in your Account Settings or Profile page under 'API' or 'Integrations'." **Take me to the settings page** reopens the site where you left it, so you can highlight the key and use Copy Selection.

**Sites that need a login: let the app find your key.** When Analyze gets an authorization error, the address is kept and a **Requires Authentication** banner appears. The API key fields open below it (key in the address, named `api_key` until the site shows otherwise).
1. Tap **Log in to find my key**. The site opens in a page styled like the app, and you log in there yourself.
2. Go to the page that shows your key (usually Account, Profile or Settings) and tap **Find Key on Page** in the bottom toolbar.
3. The app reads the page by context, not by guessing random long strings:
   - text right after a label such as "API Key", "API Token", "Secret" or "Credentials", including a value on the line below the label;
   - `api_key=…` / `user_id=…` anywhere: in example addresses, or inside a text box (even `&api_key=…&user_id=…` combined in one box, which fills both fields). This also gives the parameter names;
   - a text box labeled as the key.
   A user ID is found the same way.
   If you highlight text before tapping Find Key on Page, that text is read first.
4. With one key, the form is filled in, the page closes with a confirmation, and Test Connection runs on its own. With several, a picker shows each one with where it was found (for example "Found next to 'API Key'"). If none is found, you're told which page to open.

Try it with **Try a demo address › Demo Vault (log in to find the key)**: log in with demo / demo. The account page has a single key. Its **Developer settings** page has two, so you can try the picker.

1. Paste the site's search address with `{tags}` and `{page}` (or `{cursor}`) placeholders, and type a sample tag that has results. **Try a demo address** fills in demo examples.
2. Tap **Analyze**. MediaDeck downloads page 1, finds the list of results, looks at the first three, and proposes every field.
3. Each field shows a dot (green = sure, yellow = likely, red = check this) and one sentence saying exactly why it was chosen.
4. The preview shows the first 5 results built from the proposal; a broken result shows the failing field in red.
5. **Test** runs a real search, **Edit fields** opens the normal form, and **Save adapter** adds the site and opens it in Browse. Sites with red-dot fields get a red badge on their Browse tab that opens the form at those fields.
6. If the site needs a login, Analyze says so and asks you to choose the login style (it never guesses), then run Analyze again.

Failures are explained in plain English with one next step: bad address, unreachable server, HTTP error (with the server's text), a web page instead of an API, or no list found (with a button to the Field Mapper).

---

## What's new (Phases 1–20)

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
- Messages appear near the bottom of the screen and can be dismissed with ✕ or a swipe down.

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

**Privacy and management (Phase 13)**
- **Decoy passcode** (Settings › Security, once a passcode is on): entering it opens MediaDeck looking unused. There are no favorites, collections, history, saved searches or downloads, and only the built-in demo sites. Nothing is deleted, nothing new is saved, and Security shows only Lock Now. Your real passcode brings everything back.
- **Storage** (Settings › Data › Storage): a chart of what takes space (cache per site, downloads per site, the library database, web pages).
- **Hold a tag** in the Info panel for Search, Add to Current Search, Exclude from Search, Copy Tag, About This Tag, and Blacklist / Remove from Blacklist. A plain tap still searches.
- **Full-size media only on Wi-Fi** (Settings › Battery and data): on mobile data, only thumbnails load until you tap **Load on Mobile Data** or **Play on Mobile Data**.
- **Back Up Everything / Restore from Backup** (Settings › Data): one JSON file with settings, adapters, favorites, collections, history, saved searches, themes and reverse search engines. Passwords, API keys and the passcode are never included. Restoring only adds what's missing.
- **iPad:** works in Split View and Slide Over; the grid adds columns only when the window is wide.

**iOS integration (Phase 14)**
- **Share to MediaDeck:** in any app's share sheet, tap More › MediaDeck once to add it to the row. A shared link to one of your sites opens that post or search. A shared picture opens with **Find Where It Comes From** (reverse search).
- **Picture in Picture:** the PiP button in the video controls, or just go to the Home Screen while a video plays. The floating video keeps playing after you close the viewer.
- **Random Favorite widget:** long-press the Home Screen › + › MediaDeck. It shows one of your favorites and changes every hour; tapping it opens Favorites.
- **Play alongside other audio** (Settings › Appearance): video sound mixes with music or podcasts instead of stopping them.
- **Photo details (EXIF):** the Info panel shows camera, lens, shutter, aperture, ISO, date, software and color profile when the file has them, and warns if it contains the place where it was taken.
- **Back to top:** a floating ↑ button appears after scrolling a long way down a grid.

**Layouts and workflows (Phase 15)**
- **Masonry grid:** Settings › Appearance › Thumbnail shape › Masonry (staggered). Thumbnails keep their shape in staggered columns.
- **Read Later:** long-press a thumbnail (or ⋯ in the viewer) › Read Later. Find them in Favorites › Later; **Clear Viewed** removes the ones you've opened.
- **Build a Search** (Browse › ⋯ menu): add tags as "Must have" or "Leave out" with suggestions from the site, pick sort and rating, and see the exact search text it will use.
- **Downloads:** swipe a row right for Pause / Resume / Retry, or left to Cancel.
- **Tag translations:** hold a tag › Translate Tag…, or Settings › Browsing › Tag Translations. Your name is shown on the tag, and typing it in a search sends the site's tag. They're stored in `tag_translations.json` as `{"site tag": "your name"}`.
- No iCloud sync, as requested: use Settings › Data › Back Up Everything (backups also include Read Later and tag translations).

**Smarter and more personal (Phase 16)**
- **Smart square thumbnails** (Settings › Appearance, on by default): square thumbnails are cropped around the most eye-catching part of the picture instead of always the middle. The analysis runs on the phone in the background, and each result is remembered.
- **Smart collections** (Favorites › Collections › New Smart Collection): rules such as has all / any / none of some tags, from certain sites, of a type, by an uploader, or added recently. Matching favorites appear by themselves.
- **Suggestions everywhere:** while typing, suggestions come from the site (every site in an All Sites tab) plus tags already on your phone: favorites, Read Later, open results, history and your translations.
- **Gestures** (Settings › Reading): choose what a double tap (Zoom, Favorite, Info, Next post, Read Later, Nothing), a swipe up (Hide posts like this, Info, Favorite, Download, Read Later, Nothing) and a swipe down (Close / Nothing) do.
- **Edit Picture** (viewer ⋯): rotate, flip, crop to 1:1 / 4:5 / 16:9, plus brightness, contrast and saturation. Share the result, or save it to Photos or Files. The original is never changed.

**On-device intelligence and background work (Phase 17)**
- **Find Text in Picture** (Info panel): reads the text in a picture on the phone; select or copy it.
- **Look-alike favorites** (Favorites › the two-squares button): finds favorites that look alike, with Loose / Normal / Strict matching, and lets you unfavorite extras.
- **Two pages side by side** when the phone is sideways (Settings › Reading). It follows right-to-left mode, and edge taps turn a whole spread.
- **Watch saved searches:** swipe a saved search right (or hold it) › Watch. MediaDeck checks for new posts when iOS gives it background time and whenever you open the app (at most every 15 minutes). The saved search then shows **N new**, and you get a notification if the app was in the background.
- **Grab a video frame:** the camera button in the video controls saves the current frame (Share, Photos, Files, or Edit).
- **Debug console:** Settings › About › tap Version 5 times. It shows a live log, including every request with status, time and size; keys, tokens and passwords in addresses appear as •••. It can also run the saved-search check now.
- The demo search **rotating** (Demo Site A) changes its results every minute, for trying Watch.

**Links and upscaling (Phase 18)**
- **Links that open MediaDeck:** `mediadeck://search?tag=blue&site=demo-a` runs a search, and `mediadeck://post?id=12&site=demo-a` opens a post. `site` is an adapter id or display name; leave it out to use the open site.
- **Upscale:** Edit Picture › Size when saved › 2× or 3× larger, using high-quality (Lanczos) enlarging with light sharpening. It shows the saved size, and the long side is capped at 8192 px.

**Awkward formats (Phase 19)**
- **ZIP animations:** addresses ending in `.zip` (adapter `zipExtensions`) are unzipped on the phone and played like a GIF. Frame timings come from the site's JSON (`zipFramesPath`, a list like `[{"file": "000.jpg", "delay": 80}]`), else from an `animation.json` inside the ZIP, else 100 ms per frame.
- **Animated WebP and APNG** play with their own frame timings.
- **HLS streams** (`.m3u8`) play in the native player (added to the default video types). They can't be downloaded, and saying so is the only thing Download does for them.
- **File endings ignore capitals:** `.JPG`, `.MP4` and `.ZIP` work like `.jpg`, `.mp4` and `.zip`.
- **Clear errors:** an empty file says "File not found on server", and a web page where a picture or file was expected says "Site blocked request or requires login" (viewer, grid and downloads).
- Auto-Configure › Try a demo address › **Demo Formats** shows one post per case.

**Library power tools (Phase 20)**
- **Save as CBZ:** in a gallery, use the box button next to the page counter (or ⋯ › Save as CBZ). Pages are downloaded, keep their own type, are named 001.jpg, 002.png… and packed into a `.cbz` you save to Files.
- **Generate External Archive:** with `externalArchiveURL` set (for example `https://…/g/{id}?format=cbz`), ⋯ in a gallery opens that page in the themed browser with `{id}` filled in.
- **Pools tab:** browse and search a site's pools (series, comics) and read one in order. Adapter fields: `poolsPath` (with `{page}`, `{query}`), `poolsResultsPath`, `poolIDPath`, `poolNamePath`, `poolCountPath`, and either `poolPostIDsPath` (IDs in reading order) or `poolSearchTemplate` (e.g. `pool:{id}`). The demo Site A has pools.
- **The download queue now opens from the Library** (the arrow button, with a count badge on the Library tab), because iOS shows only five tabs before hiding the rest under "More".
- **Reverse Search Selected:** select posts in Browse › magnifying-glass button. They're searched one by one with your reverse search engine, and the report lists sources, posts with no source, groups that share a source (likely duplicates), and matches already on one of your sites. Copy the report with the button at the top. To use the SauceNAO JSON API, add it as an engine in Settings › Tools › Reverse Search with your own key; MediaDeck doesn't ship any service.
- **Fallback site** (Settings › Reading): when a search fails because the site is down or busy (timeout, 429, 5xx), MediaDeck asks "<site> is offline. Switch to <fallback> for this search?" and only switches if you tap Switch.

**Shortcuts:** "Search in MediaDeck" asks for tags and opens the app on that search (iOS 16+).

### New adapters.json fields (all optional)
`alternateMediaURLPaths`, `tagSpaceReplacement`, `autocompletePath`, `autocompleteResultsPath`, `autocompleteNameKey`, `randomTag`, `relatedTagsPath`, `wikiPath`, `tagAliasesPath`, `votePath`, `accountSettingsPath`, `registerURL`, `authUserParamName`, `apiKeyPageURL`, `favoritePath`, `tagCategoryKey`, `galleryPath`, `galleryURLKey`, `zipExtensions`, `zipFramesPath`, `externalArchiveURL`, `poolsPath`, `poolsResultsPath`, `poolIDPath`, `poolNamePath`, `poolCountPath`, `poolPostIDsPath`, `poolSearchTemplate`, and the `bearer` login style. `m3u8` is now in the default `videoExtensions`. `metadataPaths` can also hold an `uploader` entry.

Each is explained in Settings › Sites & Adapters › Field Guide. Features whose field is empty don't appear in the app.
