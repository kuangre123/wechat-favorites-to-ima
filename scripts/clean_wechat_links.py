#!/usr/bin/env python3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from wechat_favorites_to_ima.cli import extract_links, render_markdown


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
