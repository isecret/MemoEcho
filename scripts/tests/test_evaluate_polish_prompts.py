"""Ensure technical dictation evaluation detects character-level regressions."""
import importlib.util
import json
from pathlib import Path
import unittest
from tempfile import TemporaryDirectory
from unittest.mock import patch

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
        expected = {case[0] for suite in ["standard", "technical", "filler", "repetition", "continuation", "chinese"]
                    for case in evaluation.suite_cases(suite)}
        self.assertEqual(set(ids), expected)
        self.assertEqual(len(ids), len(set(ids)))
        self.assertIn("leading_action", ids)
        self.assertIn("repeat_ok", ids)
        self.assertIn("continuation_cancel", ids)
        self.assertIn("chinese_reversal", ids)

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

    def test_continuation_requires_connected_semantics_without_duplicate_fragments(self):
        for name in ["continuation_cancel", "continuation_segments"]:
            case = next(item for item in evaluation.CONTINUATION_CASES if item[0] == name)
            prefix = "创建一个 bug：当前 Thinking 阶段，HUD 过程中，"
            for text, passed in [("我按下 ESC 没有办法取消这个任务。", True),
                                 ("我按下 ESC 没有办法取消，取消这个任务。", False),
                                 ("我按下 ESC 没有办法取消。取消这个任务。", False),
                                 ("我按下 ESC 没有办法取消这个任务，取消这个任务。", False),
                                 ("我按下 ESC 没有办法取消。", False)]:
                with self.subTest(name=name, text=text):
                    content = json.dumps({"mode": "plain_text", "text": prefix + text, "correction_applied": False})
                    self.assertEqual(evaluation.assess(content, case), (True, passed))

    def test_continuation_preserves_independent_actions_and_emphasis(self):
        examples = {"continuation_distinct_actions": ("取消这个任务，再取消那个任务。", "取消这个任务。"),
                    "continuation_emphasis": ("一定要取消，一定要取消这个任务。", "一定要取消这个任务。")}
        for name, outputs in examples.items():
            case = next(item for item in evaluation.CONTINUATION_CASES if item[0] == name)
            for text, passed in zip(outputs, [True, False]):
                content = json.dumps({"mode": "plain_text", "text": text, "correction_applied": False})
                self.assertEqual(evaluation.assess(content, case), (True, passed))

    def test_polarity_reversal_and_invented_consequences_are_rejected(self):
        examples = {
            "contrast": [("这不是故障，是正常现象。", True), ("这不是故障，也不是正常现象。", False)],
            "sequence": [("先保存，然后退出。", True), ("先保存，再退出。", True),
                         ("先保存，然后退出，否则会导致永久丢失。", False),
                         ("不要先保存，然后退出，应该反过来做。", False)],
        }
        for name, outputs in examples.items():
            case = next(item for item in evaluation.CASES if item[0] == name)
            for text, passed in outputs:
                with self.subTest(name=name, text=text):
                    content = json.dumps({"mode": "plain_text", "text": text, "correction_applied": False})
                    self.assertEqual(evaluation.assess(content, case), (True, passed))

    def assess_chinese(self, name, text, correction=False):
        case = next(item for item in evaluation.CHINESE_CASES if item[0] == "chinese_" + name)
        return evaluation.assess(json.dumps({"mode": "plain_text", "text": text,
                                            "correction_applied": correction}), case)

    def test_reversal_requires_applied_edit_and_honest_correction_flag(self):
        raw = "明天先把那个功能去掉，算了，还是留着吧。"
        final = "明天先把那个功能留着吧。"
        self.assertEqual(self.assess_chinese("reversal", raw), (True, False))
        self.assertEqual(self.assess_chinese("reversal", raw, correction=True), (True, False))
        self.assertEqual(self.assess_chinese("reversal", final), (True, False))
        self.assertEqual(self.assess_chinese("reversal", final, correction=True), (True, True))

    def test_empty_error_is_expected_only_for_pure_filler(self):
        self.assertEqual(self.assess_chinese("empty_filler", ""), (True, True))
        self.assertEqual(self.assess_chinese("empty_filler", "呃。"), (True, False))
        self.assertEqual(self.assess_chinese("short_reply", ""), (True, False))
        self.assertEqual(self.assess_chinese("short_reply", "嗯。"), (True, True))

    def test_qualifiers_units_and_numeric_characters_are_not_normalized_away(self):
        examples = {
            "negative_decimal": [("数值是-0.05，误差为±0.001。", True),
                                 ("数值是0.05，误差为±0.001。", False),
                                 ("数值是-005，误差为±0001。", False)],
            "percent_units": [("上涨了10%，不是上涨了10个百分点。", True),
                              ("上涨了10个百分点，不是上涨了10%。", False)],
            "approximation": [("大概三四个人，十来分钟，二十多块钱，七八成把握。", True),
                              ("四个人，十分钟，二十块钱，八成把握。", False)],
            "numeric_identifier": [("样例编号是007012，开头两个零都要保留。", True),
                                   ("样例编号是7012，开头两个零都要保留。", False)],
            "conditions": [("只有审核通过才发布，除非负责人另有通知。", True),
                           ("审核通过就发布，不管负责人是否另有通知。", False)],
            "relative_time": [("下下周五下午2:30之前给我，不是这周五。", True),
                              ("下下周五下午230之前给我，不是这周五。", False)],
        }
        for name, outputs in examples.items():
            for text, passed in outputs:
                with self.subTest(name=name, text=text):
                    self.assertEqual(self.assess_chinese(name, text), (True, passed))

    def test_format_words_and_emotion_must_not_disappear(self):
        self.assertEqual(self.assess_chinese("format_quotes", "在你好外面加引号。"), (True, True))
        self.assertEqual(self.assess_chinese("format_quotes", "“你好”"), (True, False))
        self.assertEqual(self.assess_chinese("emotional_repeat", "好好好，你说得都对，我不争了。"), (True, True))
        self.assertEqual(self.assess_chinese("emotional_repeat", "好，你说得都对，我不争了。"), (True, False))

    def test_synthetic_context_overrides_only_the_fixture_reference_profile(self):
        case = next(item for item in evaluation.CHINESE_CASES if item[0] == "chinese_context_approximation")
        prompts = evaluation.prompts()
        self.assertEqual(evaluation.fixture_prompt(prompts["bare"], case), prompts["bare"])
        prompt = evaluation.fixture_prompt(prompts["references"], case)
        self.assertEqual(prompt.count("BEGIN_WINDOW_CONTEXT_JSON"), 1)
        self.assertIn("4000元", prompt)
        self.assertNotIn("UNRELATED_SENTINEL", prompt)

    def test_enumeration_allows_prose_but_preserves_order_and_all_information(self):
        case = next(item for item in evaluation.CASES if item[0] == "list")
        for text, passed in [("出门前记得检查：第一，带钥匙；第二，关灯。明天还要早起。", True),
                             ("出门前记得检查：第一，带钥匙；第二，关灯。", False),
                             ("出门前记得检查：第一，关灯；第二，带钥匙。明天还要早起。", False),
                             ("出门前记得检查：第一，带钥匙；第二，关灯。明天还要早起，否则会迟到。", False)]:
            content = json.dumps({"mode": "plain_text", "text": text, "correction_applied": False})
            self.assertEqual(evaluation.assess(content, case), (True, passed))

        for intro, outro, passed in [("出门前记得检查", "明天还要早起", True),
                                      ("出门前记得检查，明天还要早起", "", False)]:
            content = json.dumps({"mode": "list", "intro": intro, "items": ["带钥匙", "关灯"],
                                  "outro": outro, "correction_applied": False})
            self.assertEqual(evaluation.assess(content, case), (True, passed))

    def test_offline_reassessment_keeps_evidence_and_never_reads_credentials_or_sends(self):
        rows = [{"version": "candidate", "case": "contrast", "schema_valid": True, "semantic_pass": True,
                 "content": json.dumps({"mode": "plain_text", "text": "这不是故障，也不是正常现象。", "correction_applied": False})},
                {"version": "candidate", "case": "list", "schema_valid": True, "semantic_pass": False,
                 "content": json.dumps({"mode": "plain_text", "text": "出门前记得检查：第一，带钥匙；第二，关灯。明天还要早起。", "correction_applied": False})}]
        with TemporaryDirectory() as directory:
            source = Path(directory) / "input.json"
            output = Path(directory) / "reassessed.json"
            source.write_text(json.dumps(rows))
            with patch("sys.argv", ["eval", "--reassess", str(source), "--output", str(output)]), \
                 patch.object(Path, "home", side_effect=AssertionError("Must not read credentials")), \
                 patch.object(evaluation.urllib.request, "urlopen", side_effect=AssertionError("Must not send")), \
                 patch("builtins.print"):
                self.assertEqual(evaluation.main(), 1)
            result = json.loads(output.read_text())
            self.assertFalse(result[0]["semantic_pass"])
            self.assertTrue(result[0]["previous_assessment"]["semantic_pass"])
            self.assertTrue(result[1]["semantic_pass"])
            self.assertFalse(result[1]["previous_assessment"]["semantic_pass"])
            self.assertEqual(json.loads(source.read_text()), rows)

if __name__ == "__main__":
    unittest.main()
