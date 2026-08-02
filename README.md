# PicCloud

Native SwiftUI iPhone/iPad picture viewer for an image folder served over HTTP.

PicCloud is built for a private photo library served from a Mac or Raspberry Pi, typically over
Tailscale. The iOS app browses photos by year and album, uses square thumbnails throughout the
gallery, supports offline reuse through an on-device cache, and opens photos in a zoomable
full-screen viewer.

## iOS app features

- Year, album, and photo-grid views with square thumbnails.
- Landscape folder browsing keeps tile sizes close to portrait: the current folder cover stays on
  the left, while child folders or photos can be swiped horizontally on the right.
- Face ID / device passcode lock before opening the app and after returning from pause/background.
- Full-screen photo viewer with pinch zoom, one-finger panning, tap-to-reset, and double-tap to
  hide or show viewer controls for an image-only view.
- Memory-aware full-screen loading: the viewer requests a server-side image variant sized for the
  current portrait or landscape viewport instead of decoding ultra-large originals on the phone.
- Persistent iPhone cache using `URLCache`: JSON manifests, thumbnails, and viewed images can be
  reused after they have been loaded once.
- Launch restore: if the Pi library version is unchanged, PicCloud restores the last gallery state
  from the previous app session instead of rebuilding the visible folders from scratch.
- Native iOS share sheet from the full-screen viewer.
- Custom `In Bilder sichern` action for saving a shared image into the Photos library.
- Share Extension `In PicCloud sichern` for sending selected Photos images and movies to the Pi5.

## Import from Apple Photos

Select images or movies in Photos, tap Share, and choose `In PicCloud sichern`. PicCloud proposes
an event folder name from the oldest capture date and the locations of the five oldest items. After
confirmation, files are uploaded to the matching year on the Pi5. JPEG images go to `JPG`, movies
to `Filme`, and HEIC originals to `RAW`; each HEIC is additionally converted to a high-quality JPEG
in `JPG`. Names use `yyyyMMdd HH-mm Ort`, with `(2)`, `(3)`, and so on for the same minute/place.

The extension requests concrete HEIC/HEIF representations so Photos does not silently replace the
original with a JPEG. Capture locations are reverse-geocoded before upload. A persistent, proximity-
aware place cache reuses successful results for nearby photos and retries temporary geocoder
failures, reducing `Unbekannter Ort` results for large selections.

Files are copied into the shared app-group container before transfer. All uploads are scheduled in
an iOS background URL session, so switching apps or locking the phone does not cancel the batch.
The main app handles completion events if iOS suspends the Share Extension.

On the Pi5, a new event is assembled below the hidden `.piccloud-uploads` staging directory. The
server publishes it into `{year}/{yyyyMMdd title}` with one atomic rename only after every upload and
HEIC-to-JPEG conversion succeeds. Interrupted attempts therefore do not leave partial albums in the
gallery. Staging sessions older than 24 hours are removed when the next upload starts.

The app and extension share the configured server URL through the App Group
`group.de.michaelhein.piccloud`. The server currently relies on the private Tailscale/LAN boundary;
the upload endpoints do not provide separate application-level authentication.

## Cache and memory behavior

The app configures a shared URL cache at launch:

```text
Memory cache: 32 MB
Disk cache:   4 GB
```

Requests use a cache-first policy. If a response was already cached, the app can show it again
without asking the server. This is intended for travel/mobile use when the phone is no longer on the
same network.

Folder and album manifests are different: on launch, PicCloud first restores the last successful
gallery snapshot from the previous app session. It then checks `/version.json` before trusting that
snapshot. The response contains a small `libraryVersion` checksum derived from image paths, sizes,
and modification times. If the checksum still matches, the app keeps the restored state and behaves
as if the previous session had never ended. If it changes, the restored state and iPhone URL cache
are invalidated so the app mirrors the Pi5 folder state instead of showing stale names or old album
contents.

Within one running app session, already opened year and album lists stay in an in-memory store, so
re-entering the same folder does not require another manifest fetch.

Image and thumbnail URLs include a file-version query value. When a photo is renamed, replaced, or
modified on the Pi5, its URL changes and iOS stores a fresh cached copy under the new key.
PicCloud also invalidates older cache schemas once after app updates and retries image loads from
the server if a cached image response cannot be decoded.

Visible thumbnails are cached twice on the phone:

- as HTTP responses inside `URLCache`
- as already decoded small images on disk for fast reuse after a full app restart

This avoids paying the thumbnail decode cost again every time the app is launched.

The full-screen viewer does not load `/image/...` originals directly. It uses `/thumb/{size}/...`,
where `{size}` is derived from the current viewport and screen scale. Portrait and landscape can
therefore use different cached image variants, avoiding stale sizing after rotation while still
preventing iOS memory termination on very large photos.

When browsing full-screen photos, PicCloud prefetches the previous and next image in the background
for the current viewer size. This warms the iPhone cache and reduces visible waiting when swiping
left or right through an album.

## Start the gallery server on pi5 over Tailscale

```sh
scp Server/piccloud_server.py pi5:/tmp/piccloud_server.py
ssh pi5 'python3 -m pip install --user pillow'
ssh pi5 'python3 /tmp/piccloud_server.py --root "/data/cloud/Bilder" --host 0.0.0.0 --port 8098 --prewarm'
```

Then use this URL in the iPhone app:

```text
http://100.104.66.88:8098
```

The app loads thumbnails for album and grid views. Full-screen photos use a larger thumbnail variant.

Thumbnail cache defaults to:

```text
/data/cloud/Bilder/.piccloud-thumbs
```

## Start the gallery server on the Mac

```sh
cd "/Users/michaelhein/* X-Code/PicCloud"
python3 Server/piccloud_server.py --root "/Volumes/Pi5/data/cloud/Bilder" --port 8088
```

If macOS blocks the folder with `Operation not permitted`, grant the terminal app full disk access or run the server directly on `pi5`.

The simulator can use:

```text
http://localhost:8088
```

## Share sheet

Open any photo full screen and tap the share icon. iOS will show available targets such as AirDrop,
Messages, WhatsApp, Notes, and other installed extensions. PicCloud also adds an explicit
`In Bilder sichern` action, which saves the image into the iPhone Photos library after iOS grants
add-only Photos permission.

## App lock and viewer controls

PicCloud requires device-owner authentication before showing the gallery. On Face ID devices this
uses Face ID, with the device passcode available as the iOS fallback. The app locks again when it
becomes inactive or enters the background.

In the full-screen viewer, a single tap resets zoom and position. A double tap toggles the viewer
chrome so only the image remains visible; another double tap brings the controls back.

## Development checks

Build for the simulator without code signing:

```sh
xcodebuild -project PicCloud.xcodeproj -scheme PicCloud -sdk iphonesimulator -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

Check the Python gallery server:

```sh
python3 -m py_compile Server/piccloud_server.py
```
