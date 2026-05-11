#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import mimetypes
import pathlib
import posixpath
import re
import urllib.parse
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

try:
    from PIL import Image, ImageOps
except ImportError:
    Image = None
    ImageOps = None

try:
    from pillow_heif import register_heif_opener
except ImportError:
    register_heif_opener = None
else:
    register_heif_opener()

IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".gif", ".heic", ".heif", ".webp", ".tif", ".tiff"}
IGNORED_IMAGE_DIR_NAMES = {"raw", "filme", "movies", "videos", "video"}
YEAR_PATTERN = re.compile(r"^(19|20)\d{2}$")
EVENT_PATTERN = re.compile(r"^(19|20)\d{2}[-_. ]?\d{1,2}[-_. ]?\d{1,2}\b")


def iso_timestamp(path: pathlib.Path) -> str | None:
    try:
        modified = dt.datetime.fromtimestamp(path.stat().st_mtime, tz=dt.timezone.utc)
        return modified.isoformat().replace("+00:00", "Z")
    except OSError:
        return None


def stable_id(value: str) -> str:
    return hashlib.sha1(value.encode("utf-8")).hexdigest()[:16]


def asset_version(path: pathlib.Path) -> str:
    stat = path.stat()
    return f"{stat.st_mtime_ns:x}-{stat.st_size:x}"


def url_with_version(url: str, version: str) -> str:
    separator = "&" if "?" in url else "?"
    return f"{url}{separator}v={version}"


def should_skip_path(root: pathlib.Path, path: pathlib.Path, thumb_root: pathlib.Path) -> bool:
    try:
        path.resolve().relative_to(thumb_root.resolve())
        return True
    except ValueError:
        pass

    try:
        relative = path.relative_to(root)
    except ValueError:
        return True

    return any(part.startswith(".") for part in relative.parts)


def album_path_for(relative_path: str) -> str:
    parts = relative_path.split("/")
    parent_parts = parts[:-1]
    if not parent_parts:
        return "Alle Bilder"

    lowered = {part.casefold() for part in parent_parts}
    if lowered.intersection(IGNORED_IMAGE_DIR_NAMES):
        return ""

    first = parent_parts[0]
    if EVENT_PATTERN.match(first):
        return first

    if YEAR_PATTERN.match(first) and len(parent_parts) >= 2:
        second = parent_parts[1]
        if EVENT_PATTERN.match(second):
            return "/".join(parent_parts[:2])
        return "/".join(parent_parts[:2])

    return "/".join(parent_parts)


def album_path_for_event_dir(root: pathlib.Path, directory: pathlib.Path) -> str:
    try:
        parts = directory.relative_to(root).as_posix().split("/")
    except ValueError:
        return ""
    if not parts or any(part.startswith(".") for part in parts):
        return ""
    if any(part.casefold() in IGNORED_IMAGE_DIR_NAMES for part in parts):
        return ""
    if EVENT_PATTERN.match(parts[0]):
        return parts[0]
    if YEAR_PATTERN.match(parts[0]) and len(parts) >= 2 and EVENT_PATTERN.match(parts[1]):
        return "/".join(parts[:2])
    return ""


def year_for_album_path(album_path: str) -> str:
    first = album_path.split("/", 1)[0]
    if YEAR_PATTERN.match(first):
        return first
    match = re.match(r"^((19|20)\d{2})", first)
    if match:
        return match.group(1)
    return "Ohne Jahr"


def sort_key_for_album(album: dict) -> tuple[int, str]:
    path = album["path"]
    title = album["title"]
    match = re.search(r"((19|20)\d{2})[-_. ]?(\d{1,2})[-_. ]?(\d{1,2})", path)
    if match:
        year = int(match.group(1))
        month = int(match.group(3))
        day = int(match.group(4))
        return (year * 10000 + month * 100 + day, title.casefold())
    year = year_for_album_path(path)
    if year.isdigit():
        return (int(year) * 10000, title.casefold())
    return (0, title.casefold())


class PicCloudHandler(SimpleHTTPRequestHandler):
    gallery_root: pathlib.Path
    thumb_root: pathlib.Path
    thumb_size: int
    jpeg_quality: int

    def end_headers(self) -> None:
        self.send_header("Access-Control-Allow-Origin", "*")
        if not getattr(self, "_sent_cache_control", False):
            self.send_header("Cache-Control", "public, max-age=300")
        self._sent_cache_control = False
        super().end_headers()

    def do_GET(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/years.json":
            self.write_years()
            return
        if parsed.path.startswith("/year/") and parsed.path.endswith(".json"):
            year_id = urllib.parse.unquote(parsed.path.removeprefix("/year/").removesuffix(".json"))
            self.write_year(year_id)
            return
        if parsed.path == "/albums.json":
            self.write_manifest(include_photos=False)
            return
        if parsed.path == "/manifest.json":
            self.write_manifest(include_photos=True)
            return
        if parsed.path.startswith("/album/") and parsed.path.endswith(".json"):
            album_id = parsed.path.removeprefix("/album/").removesuffix(".json")
            self.write_album(album_id)
            return
        if parsed.path.startswith("/image/"):
            self.write_image(parsed.path.removeprefix("/image/"))
            return
        if parsed.path.startswith("/thumb/"):
            self.write_thumbnail(parsed.path.removeprefix("/thumb/"))
            return
        self.send_error(404)

    def write_json(self, payload: dict) -> None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-cache")
        self._sent_cache_control = True
        self.end_headers()
        self.wfile.write(data)

    def write_manifest(self, include_photos: bool) -> None:
        albums = self.build_albums(include_photos=include_photos)
        payload = {
            "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
            "libraryVersion": self.library_version(),
            "rootName": self.gallery_root.name,
            "albums": sorted(albums.values(), key=sort_key_for_album, reverse=True),
        }
        self.write_json(payload)

    def write_years(self) -> None:
        albums = self.build_albums(include_photos=False)
        years: dict[str, dict] = {}
        for album in albums.values():
            year = year_for_album_path(album["path"])
            entry = years.setdefault(
                year,
                {
                    "id": year,
                    "title": year,
                    "count": 0,
                    "albumCount": 0,
                    "cover": None,
                },
            )
            entry["count"] += album["count"]
            entry["albumCount"] += 1
            if album["cover"] is not None and (
                entry["cover"] is None or sort_key_for_album(album) > entry.get("_sort", (0, ""))
            ):
                entry["cover"] = album["cover"]
                entry["_sort"] = sort_key_for_album(album)

        result = []
        for year in years.values():
            year.pop("_sort", None)
            result.append(year)

        result.sort(key=lambda item: int(item["id"]) if item["id"].isdigit() else 0, reverse=True)
        payload = {
            "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
            "libraryVersion": self.library_version(),
            "rootName": self.gallery_root.name,
            "years": result,
        }
        self.write_json(payload)

    def write_year(self, year_id: str) -> None:
        albums = [
            album
            for album in self.build_albums(include_photos=False).values()
            if year_for_album_path(album["path"]) == year_id
        ]
        albums.sort(key=sort_key_for_album, reverse=True)
        payload = {
            "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
            "libraryVersion": self.library_version(),
            "rootName": self.gallery_root.name,
            "year": {
                "id": year_id,
                "title": year_id,
                "count": sum(album["count"] for album in albums),
                "albumCount": len(albums),
                "cover": next((album["cover"] for album in albums if album["cover"] is not None), None),
            },
            "albums": albums,
        }
        self.write_json(payload)

    def write_album(self, album_id: str) -> None:
        albums = self.build_albums(include_photos=True)
        for album in albums.values():
            if album["id"] == album_id:
                payload = {
                    "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
                    "libraryVersion": self.library_version(),
                    "rootName": self.gallery_root.name,
                    "album": album,
                }
                self.write_json(payload)
                return
        self.send_error(404)

    def build_albums(self, include_photos: bool) -> dict[str, dict]:
        albums: dict[str, dict] = {}
        root = self.gallery_root
        scheme = "http"
        host = self.headers.get("Host", f"localhost:{self.server.server_port}")
        base_url = f"{scheme}://{host}"

        for file_path in sorted(root.rglob("*")):
            if should_skip_path(root, file_path, self.thumb_root):
                continue
            if not file_path.is_file() or file_path.suffix.lower() not in IMAGE_EXTENSIONS:
                continue

            relative = file_path.relative_to(root).as_posix()
            album_path = album_path_for(relative)
            if not album_path:
                continue
            album_id = stable_id(album_path)
            album = albums.setdefault(
                album_path,
                {
                    "id": album_id,
                    "title": posixpath.basename(album_path) if album_path != "Alle Bilder" else "Alle Bilder",
                    "path": album_path,
                    "count": 0,
                    "cover": None,
                },
            )
            if include_photos:
                album.setdefault("photos", [])

            quoted = urllib.parse.quote(relative)
            version = asset_version(file_path)
            image_url = url_with_version(f"{base_url}/image/{quoted}", version)
            thumb_url = url_with_version(f"{base_url}/thumb/{self.thumb_size}/{quoted}", version)
            photo = {
                "id": stable_id(relative),
                "albumId": album_id,
                "name": file_path.name,
                "relativePath": relative,
                "url": image_url,
                "thumbURL": thumb_url,
                "modifiedAt": iso_timestamp(file_path),
            }
            if include_photos:
                album["photos"].append(photo)
            album["count"] += 1
            if album["cover"] is None:
                album["cover"] = photo

        for directory in root.rglob("*"):
            if not directory.is_dir() or should_skip_path(root, directory, self.thumb_root):
                continue
            album_path = album_path_for_event_dir(root, directory)
            if not album_path or album_path in albums:
                continue
            albums[album_path] = {
                "id": stable_id(album_path),
                "title": posixpath.basename(album_path),
                "path": album_path,
                "count": 0,
                "cover": None,
            }
            if include_photos:
                albums[album_path]["photos"] = []

        return albums

    def library_version(self) -> str:
        digest = hashlib.sha1()
        root = self.gallery_root
        for file_path in sorted(root.rglob("*")):
            if should_skip_path(root, file_path, self.thumb_root):
                continue
            if not file_path.is_file() or file_path.suffix.lower() not in IMAGE_EXTENSIONS:
                continue
            try:
                stat = file_path.stat()
                relative = file_path.relative_to(root).as_posix()
            except OSError:
                continue
            digest.update(relative.encode("utf-8", errors="surrogateescape"))
            digest.update(b"\0")
            digest.update(str(stat.st_size).encode("ascii"))
            digest.update(b"\0")
            digest.update(str(stat.st_mtime_ns).encode("ascii"))
            digest.update(b"\0")
        return digest.hexdigest()[:20]

    def write_image(self, quoted_relative_path: str) -> None:
        relative = urllib.parse.unquote(quoted_relative_path)
        requested = (self.gallery_root / relative).resolve()
        try:
            requested.relative_to(self.gallery_root.resolve())
        except ValueError:
            self.send_error(403)
            return

        if not requested.is_file() or requested.suffix.lower() not in IMAGE_EXTENSIONS:
            self.send_error(404)
            return

        content_type = mimetypes.guess_type(requested.name)[0] or "application/octet-stream"
        try:
            size = requested.stat().st_size
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(size))
            self.end_headers()
            with requested.open("rb") as image_file:
                self.copyfile(image_file, self.wfile)
        except OSError as error:
            self.send_error(500, str(error))

    def write_thumbnail(self, thumb_request: str) -> None:
        try:
            size_text, quoted_relative_path = thumb_request.split("/", 1)
            size = max(120, min(int(size_text), 4096))
        except ValueError:
            self.send_error(400)
            return

        source = self.image_path_from_request(quoted_relative_path)
        if source is None:
            return

        try:
            thumb = self.thumbnail_path(source, size)
            if self.thumbnail_is_stale(source, thumb):
                self.create_thumbnail(source, thumb, size)
            self.send_file(thumb, "image/jpeg")
        except Exception as error:
            self.log_error("thumbnail failed for %s: %s", source, error)
            self.send_file(source, mimetypes.guess_type(source.name)[0] or "application/octet-stream")

    def image_path_from_request(self, quoted_relative_path: str) -> pathlib.Path | None:
        relative = urllib.parse.unquote(quoted_relative_path)
        requested = (self.gallery_root / relative).resolve()
        try:
            requested.relative_to(self.gallery_root.resolve())
        except ValueError:
            self.send_error(403)
            return None

        if not requested.is_file() or requested.suffix.lower() not in IMAGE_EXTENSIONS:
            self.send_error(404)
            return None
        return requested

    def send_file(self, path: pathlib.Path, content_type: str) -> None:
        size = path.stat().st_size
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(size))
        self.end_headers()
        with path.open("rb") as image_file:
            self.copyfile(image_file, self.wfile)

    def thumbnail_path(self, source: pathlib.Path, size: int) -> pathlib.Path:
        relative = source.relative_to(self.gallery_root).as_posix()
        digest = stable_id(f"{relative}:{source.stat().st_mtime_ns}:{size}")
        return self.thumb_root / str(size) / f"{digest}.jpg"

    def thumbnail_is_stale(self, source: pathlib.Path, thumb: pathlib.Path) -> bool:
        return not thumb.exists() or thumb.stat().st_mtime < source.stat().st_mtime

    def create_thumbnail(self, source: pathlib.Path, thumb: pathlib.Path, size: int) -> None:
        thumb.parent.mkdir(parents=True, exist_ok=True)
        if Image is None or ImageOps is None:
            raise RuntimeError("Pillow is not installed. Run: python3 -m pip install pillow")
        with Image.open(source) as image:
            image = ImageOps.exif_transpose(image)
            image.thumbnail((size, size), Image.Resampling.LANCZOS)
            if image.mode not in ("RGB", "L"):
                image = image.convert("RGB")
            image.save(thumb, "JPEG", quality=self.jpeg_quality, optimize=True, progressive=True)


def main() -> None:
    parser = argparse.ArgumentParser(description="Serve a folder of images for the PicCloud iPhone app.")
    parser.add_argument("--root", default="/Volumes/Pi5/data/cloud/Bilder", help="Image root folder")
    parser.add_argument("--host", default="0.0.0.0", help="Bind address")
    parser.add_argument("--port", default=8088, type=int, help="Port")
    parser.add_argument("--thumb-root", default=None, help="Thumbnail cache folder")
    parser.add_argument("--thumb-size", default=640, type=int, help="Maximum thumbnail edge in pixels")
    parser.add_argument("--jpeg-quality", default=78, type=int, help="Thumbnail JPEG quality")
    parser.add_argument("--prewarm", action="store_true", help="Generate thumbnails before serving")
    args = parser.parse_args()

    root = pathlib.Path(args.root).expanduser().resolve()
    if not root.exists():
        raise SystemExit(f"Image root does not exist: {root}")

    PicCloudHandler.gallery_root = root
    PicCloudHandler.thumb_root = pathlib.Path(args.thumb_root or root / ".piccloud-thumbs").expanduser().resolve()
    PicCloudHandler.thumb_size = args.thumb_size
    PicCloudHandler.jpeg_quality = args.jpeg_quality

    if args.prewarm:
        if Image is None:
            raise SystemExit("Pillow is required for thumbnails. Install with: python3 -m pip install pillow")
        generated = 0
        skipped = 0
        seen = 0
        for file_path in root.rglob("*"):
            if should_skip_path(root, file_path, PicCloudHandler.thumb_root):
                continue
            if file_path.is_file() and file_path.suffix.lower() in IMAGE_EXTENSIONS:
                seen += 1
                try:
                    resolved = file_path.resolve()
                    thumb = PicCloudHandler.thumbnail_path(PicCloudHandler, resolved, args.thumb_size)
                    if PicCloudHandler.thumbnail_is_stale(PicCloudHandler, resolved, thumb):
                        PicCloudHandler.create_thumbnail(PicCloudHandler, resolved, thumb, args.thumb_size)
                        generated += 1
                except Exception as error:
                    skipped += 1
                    print(f"Skipped thumbnail for {file_path}: {error}", flush=True)
                if seen % 100 == 0:
                    print(f"Prewarm progress: scanned={seen} generated={generated} skipped={skipped}", flush=True)
        print(f"Generated thumbnails: {generated}; skipped: {skipped}; scanned: {seen}", flush=True)

    server = ThreadingHTTPServer((args.host, args.port), PicCloudHandler)
    print(f"PicCloud server: http://{args.host}:{args.port}", flush=True)
    print(f"Serving: {root}", flush=True)
    print(f"Thumbnails: {PicCloudHandler.thumb_root}", flush=True)
    if Image is None:
        print("Warning: Pillow is not installed. Thumbnails will fall back to originals.", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
