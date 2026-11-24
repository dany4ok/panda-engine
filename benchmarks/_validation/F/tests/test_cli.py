import contextlib
import io
import unittest
from cli import main


class CliTests(unittest.TestCase):
    def test_help(self):
        self.assertEqual(main(["--help"]), 0)

    def test_sum(self):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = main(["1", "2", "3"])
        self.assertEqual(rc, 0)
        self.assertEqual(buf.getvalue().strip(), "6.0")


if __name__ == "__main__":
    unittest.main()
