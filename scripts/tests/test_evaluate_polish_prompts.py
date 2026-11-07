"""Ensure technical dictation evaluation detects character-level regressions."""
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("polish_eval", Path(__file__).resolve().parents[1] / "evaluate-polish-prompts.py")
evaluation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evaluation)


class TechnicalDictationAssessmentTests(unittest.TestCase):
    def assess(self, name, text, correction=False):
        case = next(item for item in evaluation.TECHNICAL_CASES if item[0] == "technical_" + name)
        return evaluation.assess(json.dumps({"mode": "plain_text", "text": text,
                                            "correction_applied": correction}), case)

    def test_all_suite_includes_filler_and_repetition_without_duplicate_cases(self):
        cases = evaluation.suite_cases("all")
        ids = [case[0] for case in cases]
        expected = {case[0] for suite in ["standard", "technical", "filler", "repetition"]
                    for case in evaluation.suite_cases(suite)}
        self.assertEqual(set(ids), expected)
        self.assertEqual(len(ids), len(set(ids)))
        self.assertIn("leading_action", ids)
        self.assertIn("repeat_ok", ids)

    def test_accepts_exact_literals(self):
        for name, item in evaluation.TECHNICAL_BY_ID.items():
            if "exact" in item:
                with self.subTest(name=name):
                    self.assertEqual(self.assess(item["id"], item["exact"]), (True, True))

    def test_detects_punctuation_spaces_case_and_invented_protocol(self):
        mutations = {"dot_env": ["env", ".ENV", ".env.", ".env。", "`.env`", ". env"],
                     "domain": ["pexamplecom", "p. example.com", "p.example.com。", "https://p.example.com"],
                     "case_preservation": ["src/config/readme.md"],
                     "ambiguous_identifier": ["user_name", "userName"]}
        for name, outputs in mutations.items():
            for output in outputs:
                with self.subTest(name=name, output=output):
                    self.assertEqual(self.assess(name, output), (True, False))

    def test_ordinary_chinese_and_literal_reading_are_protected(self):
        self.assertEqual(self.assess("chinese_dot", "我晚点到，还有一点事情。"), (True, True))
        self.assertEqual(self.assess("chinese_dot", "我晚.到，还有一.事情。"), (True, False))
        self.assertEqual(self.assess("literal_reading", "保留中文读法点 ENV。"), (True, True))
        self.assertEqual(self.assess("literal_reading", "保留 .env。"), (True, False))

    def test_symbol_conversion_is_not_explicit_self_correction(self):
        self.assertEqual(self.assess("dot_env", ".env", correction=True), (True, False))

    def test_enumeration_accepts_both_modes_but_requires_exact_technical_fragments(self):
        case = next(item for item in evaluation.TECHNICAL_CASES if item[0] == "technical_list")
        for items, passed in [([".env", "package.json"], True), (["env", "package.json"], False),
                              (["点 env", "package 点 json"], False)]:
            content = json.dumps({"mode": "list", "items": items, "correction_applied": False})
            self.assertEqual(evaluation.assess(content, case), (True, passed))
        self.assertEqual(self.assess("list", "需要两个文件，第一是 .env，第二是 package.json。"), (True, True))

    def test_repetition_counts_detect_duplicates_across_punctuation(self):
        case = next(item for item in evaluation.REPETITION_CASES if item[0] == "repeat_ok")
        for text, passed in [("好的。", True), ("好的好的。", False), ("好的，好的。", False), ("好的。好的。", False)]:
            content = json.dumps({"mode": "plain_text", "text": text, "correction_applied": False})
            self.assertEqual(evaluation.assess(content, case), (True, passed))

    def test_emphasis_must_keep_both_occurrences(self):
        case = next(item for item in evaluation.REPETITION_CASES if item[0] == "intentional_emphasis")
        for text, passed in [("这件事非常非常重要。", True), ("这件事非常重要。", False)]:
            content = json.dumps({"mode": "plain_text", "text": text, "correction_applied": False})
            self.assertEqual(evaluation.assess(content, case), (True, passed))


if __name__ == "__main__":
    unittest.main()
