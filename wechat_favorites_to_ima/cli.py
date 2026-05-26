#!/usr/bin/env python3
import argparse
import re
from pathlib import Path


LINK_RE = re.compile(r"https://mp\.weixin\.qq\.com/s(?:/[A-Za-z0-9_-]+|\?[^\s]+)")
PREFIX = "https://mp.weixin.qq.com/s"


def clean_link(url: str) -> str:
    url = url.strip()
    embedded = url.find(PREFIX, len(PREFIX))
    if embedded > 0:
        url = url[:embedded]
    if url.startswith(PREFIX + "/") and url.endswith("https"):
        url = url[:-5]
    return url


def extract_links(text: str) -> list[str]:
    seen = set()
    links = []
    for match in LINK_RE.finditer(text):
        url = clean_link(match.group(0))
        if url and url not in seen:
            seen.add(url)
            links.append(url)
    return links


def render_markdown(links: list[str]) -> str:
    lines = ["# 微信收藏文章", ""]
    lines.extend(f"{idx}. {url}" for idx, url in enumerate(links, 1))
    lines.append("")
    return "\n".join(lines)


def write_batches(links: list[str], batch_dir: Path, batch_size: int) -> list[Path]:
    batch_dir.mkdir(parents=True, exist_ok=True)
    written = []
    for idx in range(0, len(links), batch_size):
        batch_no = idx // batch_size + 1
        path = batch_dir / f"batch_{batch_no:03d}.txt"
        path.write_text("\n".join(links[idx : idx + batch_size]) + "\n", encoding="utf-8")
        written.append(path)
    return written


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Clean WeChat Favorites article links and prepare ima batch import files."
    )
    parser.add_argument("source", type=Path, help="Raw links text copied from WeChat Favorites.")
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=Path("wechat_favorite_articles.md"),
        help="Markdown output path. Defaults to wechat_favorite_articles.md.",
    )
    parser.add_argument(
        "--batch-dir",
        type=Path,
        help="Optional directory for ima batch text files.",
    )
    parser.add_argument(
        "--batch-size",
        type=int,
        default=10,
        help="Links per ima batch file. Defaults to 10.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.batch_size <= 0:
        raise SystemExit("--batch-size must be greater than 0")

    text = args.source.read_text(encoding="utf-8")
    links = extract_links(text)
    args.output.write_text(render_markdown(links), encoding="utf-8")

    print(f"{len(links)} unique WeChat article links -> {args.output}")
    if args.batch_dir:
        batch_files = write_batches(links, args.batch_dir, args.batch_size)
        print(f"{len(batch_files)} ima batch files -> {args.batch_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
