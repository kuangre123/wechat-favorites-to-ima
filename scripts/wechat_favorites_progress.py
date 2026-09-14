#!/usr/bin/env python3
import argparse
import json
import os
import re
import tempfile
from datetime import datetime, timezone
from pathlib import Path


LINK_RE = re.compile(r"https?://mp\.weixin\.qq\.com/s(?:/[A-Za-z0-9_-]+|\?[^\s]+)")
PREFIX = "https://mp.weixin.qq.com/s"


def clean_link(url: str) -> str:
    url = url.strip()
    if url.startswith("http://mp.weixin.qq.com/s"):
        url = "https://" + url[len("http://") :]
    embedded = url.find(PREFIX, len(PREFIX))
    if embedded > 0:
        url = url[:embedded]
    if url.startswith(PREFIX + "/") and url.endswith("https"):
        url = url[:-5]
    return url


def extract_links(text: str) -> list[str]:
    links = []
    seen = set()
    for match in LINK_RE.finditer(text):
        url = clean_link(match.group(0))
        if url and url not in seen:
            seen.add(url)
            links.append(url)
    return links


def load_links(path: Path) -> list[str]:
    if not path.exists():
        return []
    return extract_links(path.read_text(encoding="utf-8", errors="ignore"))


def atomic_write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, path)
    finally:
        if os.path.exists(temporary_name):
            os.unlink(temporary_name)


def write_link_lines(path: Path, links: list[str]) -> None:
    atomic_write_text(path, "\n".join(links) + ("\n" if links else ""))


def ordered_unique(items: list[str]) -> list[str]:
    seen = set()
    unique = []
    for item in items:
        if item not in seen:
            seen.add(item)
            unique.append(item)
    return unique


def load_json(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


def snapshot(export_dir: Path, target: int) -> dict:
    raw_path = export_dir / "links_full_raw.txt"
    imported_path = export_dir / "imported_links.txt"
    unique_path = export_dir / "links_unique.txt"
    pending_path = export_dir / "pending_links.txt"
    progress_path = export_dir / "progress.json"
    capture_state_path = export_dir / "capture_state.json"
    inflight_path = export_dir / "import_inflight.json"

    raw = ordered_unique(load_links(raw_path))
    imported = set(load_links(imported_path))
    pending_all = [url for url in raw if url not in imported]
    pending_target = pending_all[:target]
    capture_state = load_json(capture_state_path)
    processed_rows = capture_state.get("processedRowFingerprints", [])
    inflight = load_json(inflight_path)

    write_link_lines(unique_path, raw)
    write_link_lines(pending_path, pending_target)

    data = {
        "updated_at": datetime.now(timezone.utc).isoformat(),
        "raw_unique_count": len(raw),
        "imported_count": len(imported),
        "pending_count": len(pending_all),
        "pending_target_count": len(pending_target),
        "processed_row_count": len(processed_rows) if isinstance(processed_rows, list) else 0,
        "import_inflight": {
            "batch": inflight.get("batch"),
            "phase": inflight.get("phase"),
        } if inflight else None,
        "target": target,
        "files": {
            "raw": str(raw_path),
            "imported": str(imported_path),
            "unique": str(unique_path),
            "pending": str(pending_path),
        },
    }
    atomic_write_text(progress_path, json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    return data


def mark_imported(export_dir: Path, source: Path) -> dict:
    imported_path = export_dir / "imported_links.txt"
    existing = load_links(imported_path)
    additions = load_links(source)
    merged = ordered_unique(existing + additions)
    write_link_lines(imported_path, merged)
    return snapshot(export_dir, target=0)


def main() -> int:
    parser = argparse.ArgumentParser(description="Track WeChat Favorites to ima progress.")
    parser.add_argument("--dir", type=Path, default=Path("tmp/wechat_favorites_export"))
    parser.add_argument("--target", type=int, default=100)
    sub = parser.add_subparsers(dest="command")
    sub.add_parser("refresh")
    mark = sub.add_parser("mark-imported")
    mark.add_argument("source", type=Path)
    args = parser.parse_args()

    args.dir.mkdir(parents=True, exist_ok=True)
    if args.command in (None, "refresh"):
        data = snapshot(args.dir, args.target)
    elif args.command == "mark-imported":
        data = mark_imported(args.dir, args.source)
    else:
        parser.error("unknown command")

    print(json.dumps(data, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
