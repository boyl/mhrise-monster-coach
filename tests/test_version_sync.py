import re
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[1]


class VersionSyncTests(unittest.TestCase):
    def test_runtime_load_evidence_uses_repository_version(self):
        version = (REPOSITORY / "VERSION").read_text(encoding="utf-8").strip()
        app = (REPOSITORY / "reframework/autorun/MHRiseMonsterCoach/app.lua").read_text(
            encoding="utf-8"
        )
        match = re.search(r'\[MHRiseMonsterCoach\] ([^" ]+) loaded;', app)
        self.assertIsNotNone(match, "runtime load log must expose an auditable version")
        self.assertEqual(match.group(1), version)


if __name__ == "__main__":
    unittest.main()
