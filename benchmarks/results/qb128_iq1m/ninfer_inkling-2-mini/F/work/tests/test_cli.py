import contextlib
import io
import unittest
from cli import main


class CliTests(unittest.TestCase):
    def test_help(self):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = main(["--help"])
        self.assertEqual(rc, 0)
        self.assertIn("usage", buf.getvalue().lower())

    def test_sum(self):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = main(["1", "2", "3"])
        self.assertEqual(rc, 0)
        self.assertEqual(buf.getvalue().strip(), "6.0")


if __name__ == "__main__":
    unittest.main()
