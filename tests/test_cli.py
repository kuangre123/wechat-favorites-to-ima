import tempfile
import unittest
from pathlib import Path

from wechat_favorites_to_ima.cli import extract_links, write_batches


class CliTests(unittest.TestCase):
    def test_extract_links_normalizes_and_deduplicates(self):
        short = "https://mp.weixin.qq.com/s/article-one"
        text = "\n".join(
            [
                "http://mp.weixin.qq.com/s/article-one",
                short,
                "https://example.com/ignored",
            ]
        )

        self.assertEqual(extract_links(text), [short])

    def test_write_batches_removes_only_stale_generated_batches(self):
        with tempfile.TemporaryDirectory() as directory:
            batch_dir = Path(directory)
            stale = batch_dir / "batch_003.txt"
            keep = batch_dir / "notes.txt"
            stale.write_text("stale\n", encoding="utf-8")
            keep.write_text("keep\n", encoding="utf-8")
            links = [f"https://mp.weixin.qq.com/s/item-{index}" for index in range(11)]

            written = write_batches(links, batch_dir, batch_size=10)

            self.assertEqual([path.name for path in written], ["batch_001.txt", "batch_002.txt"])
            self.assertFalse(stale.exists())
            self.assertTrue(keep.exists())


if __name__ == "__main__":
    unittest.main()
