import csv
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("performance", Path(__file__).with_name("summarize-performance.py"))
performance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(performance)


class PerformanceSummaryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "samples.csv"
        self.rows = [[operation, n, n, 1000] for operation in
                     ("wardrobe_first_page", "wardrobe_last_page", "garment_detail", "sync_snapshot")
                     for n in range(100, 0, -1)]

    def write(self):
        with self.path.open("w", newline="") as output:
            writer = csv.writer(output)
            writer.writerow(["operation", "iteration", "elapsed_ms", "response_bytes"])
            writer.writerows(self.rows)

    def test_nearest_rank_percentiles_sort_raw_samples(self):
        self.write()
        for result in performance.summarize(self.path)["operations"].values():
            self.assertEqual(result["p50_ms"], 50)
            self.assertEqual(result["p95_ms"], 95)
            self.assertEqual(result["max_ms"], 100)

    def test_missing_sample_cannot_be_reported(self):
        self.rows.pop()
        self.write()
        with self.assertRaises(ValueError):
            performance.summarize(self.path)

    def test_duplicate_sample_cannot_replace_missing_sample(self):
        self.rows[-1] = self.rows[-2]
        self.write()
        with self.assertRaises(ValueError):
            performance.summarize(self.path)

    def test_nonfinite_timing_is_rejected(self):
        self.rows[0][2] = "nan"
        self.write()
        with self.assertRaises(ValueError):
            performance.summarize(self.path)


if __name__ == "__main__":
    unittest.main()
