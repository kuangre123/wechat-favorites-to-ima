# WeChat Favorites to ima Fast Sync

## Current Boundary

The trusted source remains the WeChat Favorites desktop UI. Do not read WeChat databases, caches, browser history, or WebView history as the final source for Favorites links.

The fast path is:

1. WeChat desktop Favorites list right-click copy link.
2. Local regex cleanup and progress ledger.
3. ima webpage-link batch import, 10 links per batch.

## Speed Changes

Use the compiled runner instead of invoking Swift scripts directly:

```sh
scripts/wechat_ima_fast_sync.sh compile
TARGET=100 CAPTURE_MODE=fast IMPORT_MODE=fast scripts/wechat_ima_fast_sync.sh all
```

Modes:

- `safe`: conservative sleeps for unstable UI state.
- `fast`: default for normal runs.
- `turbo`: lower waits and larger scroll jumps; use after one successful calibration.

Why this is faster:

- Swift scripts are compiled once into `tmp/wechat_favorites_build/`.
- Swift module caches are pinned to `tmp/swift-module-cache/`.
- WeChat capture waits for the context menu and clipboard changes instead of fixed sleeps.
- WeChat is activated once per run instead of once per page.
- `capture_state.json` stores hashed row fingerprints, so later runs skip rows that were already processed without copying them again.
- End-of-list detection follows repeated page signatures instead of stopping merely because several pages contain duplicates.
- ima import waits for dialog open/close state instead of fixed long sleeps.
- ima uses accessibility press/value actions when available and falls back to mouse/clipboard input.
- Pending batches live in `pending_batches/`; historical `batches/` files are not deleted.
- `import_inflight.json` records the current submission phase. An uncertain submission is never retried automatically.
- `.sync.lock` prevents two UI automation runs from racing and importing the same pending batch.
- Progress manifests are replaced atomically, so interruption cannot leave a half-written ledger.
- Progress is tracked through `capture_state.json`, `imported_links.txt`, `pending_links.txt`, and `progress.json`.

## Runtime Dependencies

Holo3.1 is not part of the sync path and does not need to be downloaded or started. This workflow has fixed actions and observable UI states, so a local state machine is faster and more predictable than model inference.

Required components are macOS, Swift, Python 3, WeChat desktop, ima desktop, Accessibility permission, and Screen Recording permission. `cliclick` is an optional fallback when native mouse events are unreliable.

## Interrupted Import Recovery

If `import_inflight.json` reports an uncertain submission, first check ima and then choose explicitly:

```sh
RESOLVE_INFLIGHT=submitted scripts/wechat_ima_fast_sync.sh import
RESOLVE_INFLIGHT=retry scripts/wechat_ima_fast_sync.sh import
```
