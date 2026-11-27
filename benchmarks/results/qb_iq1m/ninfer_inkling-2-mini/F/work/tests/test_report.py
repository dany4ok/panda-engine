import unittest
from report import summarize


class ReportTests(unittest.TestCase):
    def test_summarize(self):
        got = summarize([{"name": "a", "score": 2}, {"name": "b", "score": 4}])
        self.assertEqual(got, {"count": 2, "total": 6, "avg": 3.0})


if __name__ == "__main__":
    unittest.main()
