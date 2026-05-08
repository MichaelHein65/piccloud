# PicCloud

Native SwiftUI iPhone/iPad picture viewer for an image folder served over HTTP.

PicCloud is built for a private photo library served from a Mac or Raspberry Pi, typically over
Tailscale. The iOS app browses photos by year and album, uses square thumbnails throughout the
gallery, supports offline reuse through an on-device cache, and opens photos in a zoomable
full-screen viewer.

## iOS app features

- Year, album, and photo-grid views with square thumbnails.
- Full-screen photo viewer with pinch zoom, one-finger panning, and tap-to-reset.
- Memory-aware full-screen loading: the viewer requests a server-side image variant sized for the
  current portrait or landscape viewport instead of decoding ultra-large originals on the phone.
- Persistent iPhone cache using `URLCache`: JSON manifests, thumbnails, and viewed images can be
  reused after they have been loaded once.
- Native iOS share sheet from the full-screen viewer.
- Custom `In Bilder sichern` action for saving a shared image into the Photos library.

## Cache and memory behavior

The app configures a shared URL cache at launch:

```text
Memory cache: 32 MB
Disk cache:   4 GB
```

Requests use a cache-first policy. If a response was already cached, the app can show it again
without asking the server. This is intended for travel/mobile use when the phone is no longer on the
same network.

The full-screen viewer does not load `/image/...` originals directly. It uses `/thumb/{size}/...`,
where `{size}` is derived from the current viewport and screen scale. Portrait and landscape can
therefore use different cached image variants, avoiding stale sizing after rotation while still
preventing iOS memory termination on very large photos.

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

## Development checks

Build for the simulator without code signing:

```sh
xcodebuild -project PicCloud.xcodeproj -scheme PicCloud -sdk iphonesimulator -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

Check the Python gallery server:

```sh
python3 -m py_compile Server/piccloud_server.py
```
