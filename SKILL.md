---
name: wechat-favorites-to-ima
description: Use in Codex Desktop with Computer Use on macOS when migrating WeChat Favorites articles into ima.copilot knowledge bases. This workflow is tested on Mac. Codex should operate the WeChat and ima desktop UIs with Computer Use, extract only trusted article URLs by right-clicking WeChat Favorites list items, filter mp.weixin.qq.com/s links, deduplicate them, and import them through ima's "网页链接" batch importer.
---

# WeChat Favorites To ima

## Purpose

Move WeChat Favorites articles into an ima knowledge base with minimal user involvement.

The trusted source is the WeChat Favorites UI itself. Do not mine WeChat cache, WebView history, browser history, or local databases as the final source because those URLs may not belong to the user's Favorites.

This skill is designed and tested on Mac with Codex Desktop plus Computer Use:

- Use Computer Use to operate WeChat and ima desktop windows.
- Use shell or the bundled CLI only for local cleaning, deduplication, and batch file generation.
- The CLI cannot read WeChat Favorites or import into ima by itself; UI automation is part of the skill.
- macOS is the tested platform. Other desktop platforms are not validated by this skill.

## Usage Example

```text
Use $wechat-favorites-to-ima in Codex Desktop with Computer Use to operate WeChat and ima: read all WeChat Favorites article links from the Favorites list, keep only mp.weixin.qq.com/s URLs, deduplicate them, and import all cleaned links into ima through "网页链接" in batches of 10.
```

## Preconditions

- WeChat desktop is logged in.
- ima.copilot is logged in and the target knowledge base is open.
- Codex Desktop can use Computer Use to click, right-click, scroll, paste, and inspect the WeChat and ima UIs.
- macOS Screen Recording and Accessibility permissions are enabled for the agent/tooling.
- The workflow has been tested on macOS with WeChat desktop and ima.copilot desktop.
- The user has opened WeChat Favorites and selected the relevant category, usually "链接".
- Operate only on the main display unless the user explicitly asks otherwise.

## Scope Rules

- Import only WeChat public article URLs matching `mp.weixin.qq.com/s`.
- Keep both short links and long query links:
  - `https://mp.weixin.qq.com/s/<id>`
  - `https://mp.weixin.qq.com/s?...`
- Skip App Store links, GitHub links, normal websites, video accounts, chat records, files, and empty clipboard results.
- Do not open articles as the primary extraction path.

## Fast Extraction Workflow

1. In WeChat Favorites list, right-click an article row.
2. Click the context menu "复制链接".
3. Read the clipboard.
4. Append only if clipboard contains `mp.weixin.qq.com/s`.
5. Scroll the Favorites list and repeat until done.
6. Deduplicate and clean malformed copied text.
7. Import into ima using "添加链接 / 上传 -> 网页链接".

## Coordinate Strategy

Prefer stable relative coordinates after calibration.

Example after right-clicking a row at `(x, y)`:

- right-click: `(x, y)`
- click "复制链接": `(x + 20, y + 5)`

Use this only after one successful calibration. If it fails, recalibrate on the visible context menu instead of opening the article.

## Local Files

Use a temporary export directory such as:

```txt
tmp/wechat_favorites_export/
```

Recommended files:

```txt
links.txt
links_full_raw.txt
wechat_favorite_articles.md
```

`links_full_raw.txt` is append-only raw copied output across multiple sessions. `wechat_favorite_articles.md` is the cleaned deduplicated import manifest for links already imported into ima.

## Cleaning Rules

Extract links with support for both formats:

```regex
https://mp\.weixin\.qq\.com/s(?:/[A-Za-z0-9_-]+|\?[^\s]+)
```

Then:

- Remove duplicate URLs.
- Fix accidental pasted concatenation.
- Remove trailing pollution such as an extra `https`.
- Preserve query parameters and fragments for long WeChat links.

Use the bundled cleaner when available:

```sh
wechat-favorites-to-ima links.txt -o wechat_favorite_articles.md --batch-dir batches
```

If the CLI is not installed, use the compatibility script:

```sh
python3 scripts/clean_wechat_links.py links.txt wechat_favorite_articles.md
```

For multi-session imports, track progress and create only-new pending batches:

```sh
wechat-favorites-progress tmp/wechat_favorites_export/links_full_raw.txt \
  --imported wechat_favorite_articles.md \
  --output-dir tmp/wechat_favorites_export
```

Only import files under `pending_batches/`. After ima accepts those links, merge the successful links into `wechat_favorite_articles.md` so the next run can skip duplicates.

## ima Import Workflow

ima's "网页链接" dialog supports multiple links separated by newlines, usually up to 10 links per batch. Always read all cleaned links and split them dynamically; do not hard-code the total link count.

1. Open the target knowledge base in ima.
2. Click the top-right add/upload button.
3. Choose "网页链接".
4. Paste up to 10 links, newline-separated.
5. Click "导入".
6. Repeat for remaining links.
7. Verify that imported entries appear as "公众号" items.
8. Some items may show "解析中"; wait until parsing completes.

## Verification

Before reporting completion:

- Count cleaned unique links.
- Confirm ima shows the same number of imported knowledge items, allowing for visible pagination/scrolling.
- Confirm entries are WeChat article or "公众号" items.
- Keep the cleaned Markdown file as a backup import manifest.

## Failure Handling

- If clipboard is empty: skip the row.
- If clipboard is non-WeChat: skip the row.
- If the menu click opens the article: close or ignore it and recalibrate the "复制链接" offset.
- If ima rejects a batch: retry with smaller batches or one link at a time.
- If parsing stalls: report imported count separately from parsed count.
