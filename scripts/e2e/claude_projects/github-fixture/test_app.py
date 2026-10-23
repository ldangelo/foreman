import unittest

import app


class AppTest(unittest.TestCase):
    def test_add(self):
        self.assertEqual(app.add(2, 3), 5)

    def test_greeting(self):
        self.assertEqual(app.greeting("world"), "hello, world")


if __name__ == "__main__":
    unittest.main()
