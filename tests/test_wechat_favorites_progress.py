import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "wechat_favorites_progress",
    ROOT / "scripts" / "wechat_favorites_progress.py",
)
PROGRESS = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(PROGRESS)


class ProgressTests(unittest.TestCase):
    def test_snapshot_deduplicates_and_excludes_imported_links(self):
        with tempfile.TemporaryDirectory() as directory:
            export_dir = Path(directory)
            first = "https://mp.weixin.qq.com/s/first"
            second = "https://mp.weixin.qq.com/s?example=second"
            (export_dir / "links_full_raw.txt").write_text(
                f"{first}\n{first}\n{second}\nhttps://example.com/ignored\n",
                encoding="utf-8",
            )
            (export_dir / "imported_links.txt").write_text(f"{first}\n", encoding="utf-8")
            (export_dir / "capture_state.json").write_text(
                json.dumps({"processedRowFingerprints": ["one", "two"]}),
                encoding="utf-8",
            )
            (export_dir / "import_inflight.json").write_text(
                json.dumps({"batch": 3, "phase": "submitting"}),
                encoding="utf-8",
            )

            result = PROGRESS.snapshot(export_dir, target=100)

            self.assertEqual(result["raw_unique_count"], 2)
            self.assertEqual(result["imported_count"], 1)
            self.assertEqual(result["pending_count"], 1)
            self.assertEqual(result["processed_row_count"], 2)
            self.assertEqual(result["import_inflight"], {"batch": 3, "phase": "submitting"})
            self.assertEqual((export_dir / "pending_links.txt").read_text(), f"{second}\n")

    def test_mark_imported_is_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            export_dir = Path(directory)
            batch = export_dir / "batch.txt"
            link = "https://mp.weixin.qq.com/s/article"
            (export_dir / "links_full_raw.txt").write_text(f"{link}\n", encoding="utf-8")
            batch.write_text(f"{link}\n{link}\n", encoding="utf-8")

            PROGRESS.mark_imported(export_dir, batch)
            result = PROGRESS.mark_imported(export_dir, batch)

            self.assertEqual(result["imported_count"], 1)
            self.assertEqual(result["pending_count"], 0)
            self.assertEqual((export_dir / "imported_links.txt").read_text(), f"{link}\n")


if __name__ == "__main__":
    unittest.main()
