#!/usr/bin/env python3
import argparse
import json
from pathlib import Path

from wechat_favorites_to_ima.cli import extract_links, render_markdown, write_batches


def read_links(path: Path) -> list[str]:
    if not path.exists():
        return []
    return extract_links(path.read_text(encoding="utf-8"))


def write_progress(
    raw_path: Path,
    imported_path: Path,
    output_dir: Path,
    batch_size: int,
) -> dict[str, object]:
    captured_links = read_links(raw_path)
    imported_links = read_links(imported_path)
    imported_seen = set(imported_links)
    pending_links = [url for url in captured_links if url not in imported_seen]

    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "full_articles.md").write_text(
        render_markdown(captured_links, title="微信收藏文章 - 已抓取"),
        encoding="utf-8",
    )
    (output_dir / "pending_articles.md").write_text(
        render_markdown(pending_links, title="微信收藏文章 - 新增待导入"),
        encoding="utf-8",
    )

    pending_batch_dir = output_dir / "pending_batches"
    pending_batch_dir.mkdir(parents=True, exist_ok=True)
    for old_file in pending_batch_dir.glob("batch_*.txt"):
        old_file.unlink()
    batch_files = write_batches(pending_links, pending_batch_dir, batch_size)

    raw_text = raw_path.read_text(encoding="utf-8") if raw_path.exists() else ""
    raw_match_count = len(extract_links(raw_text))
    progress = {
        "raw_file": str(raw_path),
        "imported_manifest": str(imported_path),
        "raw_unique_count": raw_match_count,
        "captured_unique_count": len(captured_links),
        "imported_unique_count": len(imported_links),
        "pending_unique_count": len(pending_links),
        "duplicate_or_existing_count": max(len(captured_links) - len(pending_links), 0),
        "pending_batch_files": [str(path) for path in batch_files],
    }
    (output_dir / "progress.json").write_text(
        json.dumps(progress, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    (output_dir / "progress.md").write_text(
        "\n".join(
            [
                "# 微信收藏夹导入进度",
                "",
                "- 来源: 微信桌面端收藏夹 -> 链接分类",
                "- 可信来源: 仅使用右键菜单“复制链接”得到的剪贴板 URL",
                f"- 原始记录: `{raw_path}`",
                f"- 已导入清单: `{imported_path}`",
                f"- 已抓取唯一公众号文章: {len(captured_links)}",
                f"- 已导入基线: {len(imported_links)}",
                f"- 新增待导入: {len(pending_links)}",
                "- 导入策略: 每次先与已导入清单去重，只把新增链接生成批次并导入 ima",
                "",
            ]
        ),
        encoding="utf-8",
    )
    return progress


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Track WeChat Favorites import progress and create pending ima batches."
    )
    parser.add_argument("raw", type=Path, help="Append-only raw links copied from WeChat Favorites.")
    parser.add_argument(
        "--imported",
        type=Path,
        default=Path("wechat_favorite_articles.md"),
        help="Already imported Markdown manifest. Defaults to wechat_favorite_articles.md.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("wechat_favorites_progress"),
        help="Directory for progress.json, manifests, and pending batches.",
    )
    parser.add_argument(
        "--batch-size",
        type=int,
        default=10,
        help="Links per pending ima batch file. Defaults to 10.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.batch_size <= 0:
        raise SystemExit("--batch-size must be greater than 0")
    progress = write_progress(args.raw, args.imported, args.output_dir, args.batch_size)
    print(json.dumps(progress, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
