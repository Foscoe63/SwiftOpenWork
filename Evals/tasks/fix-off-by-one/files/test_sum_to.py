import unittest
from sum_to import sum_to


class SumTo(unittest.TestCase):
    def test_small(self):
        self.assertEqual(sum_to(3), 6)

    def test_one(self):
        self.assertEqual(sum_to(1), 1)

    def test_zero(self):
        self.assertEqual(sum_to(0), 0)


if __name__ == "__main__":
    unittest.main()
