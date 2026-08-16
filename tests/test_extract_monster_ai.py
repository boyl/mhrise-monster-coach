import tempfile
import unittest
from pathlib import Path

from tools.extract_monster_ai import (
    extract_resource_references,
    extraction_succeeded,
    load_release_list,
    resolve_references,
    seed_paths,
)


class ExtractMonsterAiTests(unittest.TestCase):
    def test_seed_paths_only_select_requested_monster_variant(self):
        entries = {
            "natives/stm/enemy/em032/00/ai_fsm_user_data/hub/main.user.2": "A",
            "natives/stm/enemy/em032/01/ai_fsm_user_data/hub/main.user.2": "B",
            "natives/stm/enemy/em001/00/ai_fsm_user_data/hub/main.user.2": "C",
        }
        self.assertEqual(
            seed_paths(entries, "em032", "00"),
            {"natives/stm/enemy/em032/00/ai_fsm_user_data/hub/main.user.2"},
        )

    def test_utf16_resource_references_are_bounded_to_monster(self):
        text = (
            "enemy/em032/common/act_tbl_user_data/action/em032_attack.user\0"
            "enemy/em001/common/act_tbl_user_data/action/em001_attack.user\0"
        )
        references = extract_resource_references(b"USR\0" + text.encode("utf-16le"), "em032")
        self.assertEqual(
            references,
            {"enemy/em032/common/act_tbl_user_data/action/em032_attack.user"},
        )

    def test_revisionless_reference_resolves_release_entry(self):
        entries = {
            "natives/stm/enemy/em032/common/action.user.2": "natives\\STM\\enemy\\em032\\common\\action.user.2"
        }
        resolved, unresolved = resolve_references({"enemy/em032/common/action.user"}, entries)
        self.assertEqual(resolved, set(entries))
        self.assertEqual(unresolved, set())

    def test_missing_reference_is_reported(self):
        resolved, unresolved = resolve_references({"enemy/em032/common/missing.user"}, {})
        self.assertEqual(resolved, set())
        self.assertEqual(unresolved, {"enemy/em032/common/missing.user"})

    def test_retool_nonzero_exit_is_allowed_only_with_extraction_summary(self):
        self.assertTrue(extraction_succeeded(1, "Extracted 0 files from patch.pak"))
        self.assertFalse(extraction_succeeded(1, "fatal error"))

    def test_release_list_accepts_bom_and_windows_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "release.list"
            path.write_text("\ufeffnatives\\STM\\enemy\\em032\\00\\main.user.2\n", encoding="utf-8")
            entries = load_release_list(path)
        self.assertIn("natives/stm/enemy/em032/00/main.user.2", entries)


if __name__ == "__main__":
    unittest.main()
