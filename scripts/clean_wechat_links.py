#!/usr/bin/env python3
import re
import sys
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


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: clean_wechat_links.py <raw-links.txt> <output.md>", file=sys.stderr)
        return 2

    source = Path(sys.argv[1])
    output = Path(sys.argv[2])
    text = source.read_text(encoding="utf-8")
    links = extract_links(text)
    output.write_text(render_markdown(links), encoding="utf-8")
    print(f"{len(links)} unique WeChat article links -> {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
