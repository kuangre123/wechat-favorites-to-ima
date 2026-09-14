import tempfile
import unittest
from pathlib import Path

from wechat_favorites_to_ima.progress import write_progress


class ProgressCliTests(unittest.TestCase):
    def test_write_progress_outputs_only_pending_batches(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            raw = root / "links_full_raw.txt"
            imported = root / "wechat_favorite_articles.md"
            output = root / "progress"
            first = "https://mp.weixin.qq.com/s/first"
            second = "https://mp.weixin.qq.com/s?__biz=second"
            third = "https://mp.weixin.qq.com/s/third"
            stale = output / "pending_batches" / "batch_003.txt"
            stale.parent.mkdir(parents=True)
            stale.write_text("stale\n", encoding="utf-8")

            raw.write_text(
                "\n".join(
                    [
                        first,
                        second,
                        "https://example.com/ignored",
                        second,
                        third,
                    ]
                ),
                encoding="utf-8",
            )
            imported.write_text(f"# imported\n\n1. {first}\n", encoding="utf-8")

            progress = write_progress(raw, imported, output, batch_size=1)

            self.assertEqual(progress["captured_unique_count"], 3)
            self.assertEqual(progress["imported_unique_count"], 1)
            self.assertEqual(progress["pending_unique_count"], 2)
            self.assertEqual(
                [Path(path).name for path in progress["pending_batch_files"]],
                ["batch_001.txt", "batch_002.txt"],
            )
            self.assertFalse(stale.exists())
            self.assertEqual((output / "pending_batches" / "batch_001.txt").read_text(), f"{second}\n")
            self.assertEqual((output / "pending_batches" / "batch_002.txt").read_text(), f"{third}\n")


if __name__ == "__main__":
    unittest.main()
