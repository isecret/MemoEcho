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

    def test_discourse_fillers_are_removed_without_losing_qualifiers(self):
        examples = {
            "filler_uncertain_opinion": [
                ("我觉得这个方案可能还需要调整，先别发布。", True),
                ("我觉得这个方案，然后就是，可能还需要调整，就是先别发布。", False),
                ("我觉得这个方案还需要调整，先别发布。", False),
                ("这个方案需要调整，不能发布。", False),
            ],
            "filler_multiple_clauses": [
                ("录音已经正常了，设置页面还有问题，快捷键偶尔失效，还得再检查。", True),
                ("录音已经正常了。然后，设置页面还有问题。然后，快捷键偶尔失效，还得再检查。", False),
                ("录音已经正常了，设置页面还有问题，还得再检查。", False),
            ],
            "filler_parallel_observations": [
                ("我看了一下这个页面，这个按钮现在有点小，颜色也不太明显，下面那段说明可能还得再改一下。", True),
                ("我看了一下这个页面，按钮现在有点小，颜色也不太明显，下面那段说明可能还得再改一下。", True),
                ("我看了一下这个页面，这个按钮有点小，颜色也不太明显，下面那段说明可能还得再改一下。", False),
            ],
        }
        for name, outputs in examples.items():
            for text, passed in outputs:
                with self.subTest(name=name, text=text):
                    self.assertEqual(self.assess_chinese(name, text), (True, passed))

    def test_repeated_connectors_keep_one_meaningful_relation(self):
        for name in ["filler_repeated_sequence", "filler_segment_boundaries"]:
            for text, passed in [
                ("我们先检查配置，然后再启动服务。", True),
                ("我们先检查配置，再启动服务。", True),
                ("我们先检查配置，然后，然后再启动服务。", False),
                ("我们先检查配置。然后。然后再启动服务。", False),
                ("我们先检查配置，启动服务。", False),
                ("我们先启动服务，再检查配置。", False),
            ]:
                with self.subTest(name=name, text=text):
                    self.assertEqual(self.assess_chinese(name, text), (True, passed))
        self.assertEqual(self.assess_chinese("filler_repeated_judgment", "这个就是我要的结果。"), (True, True))
        self.assertEqual(self.assess_chinese("filler_repeated_judgment", "这个就是，就是我要的结果。"), (True, False))
        self.assertEqual(self.assess_chinese("filler_repeated_judgment", "这个就是我要的结果。", correction=True), (True, False))

    def test_meaningful_discourse_words_and_verbatim_repeats_are_protected(self):
        for name, raw, wrongly_deleted in [
            ("filler_meaningful_judgment", "这个就是我要的，不是旁边那个。", "这个我要的，不是旁边那个。"),
            ("filler_meaningful_emphasis", "我就是不同意现在发布。", "我不同意现在发布。"),
            ("filler_meaningful_condition", "就是下雨也要去。", "下雨也要去。"),
            ("filler_verbatim_quote", "他说“然后然后，就是就是”，请保留原话。", "他说“然后，就是”，请保留原话。"),
            ("filler_distinct_sequences", "小王先备份然后升级，小李先检查然后发布。", "小王先备份然后升级。"),
            ("filler_discussing_words", "不要把“然后”和“就是”这两个词全部删掉。", "不要把这两个词全部删掉。"),
        ]:
            with self.subTest(name=name):
                self.assertEqual(self.assess_chinese(name, raw), (True, True))
                self.assertEqual(self.assess_chinese(name, wrongly_deleted), (True, False))

    def test_synthetic_context_overrides_only_the_fixture_reference_profile(self):
        case = next(item for item in evaluation.CHINESE_CASES if item[0] == "chinese_context_approximation")
        prompts = evaluation.prompts()
        self.assertEqual(evaluation.fixture_prompt(prompts["bare"], case), prompts["bare"])
        prompt = evaluation.fixture_prompt(prompts["references"], case)
        self.assertEqual(prompt.count("BEGIN_WINDOW_CONTEXT_JSON"), 1)
        self.assertIn("4000元", prompt)
        self.assertNotIn("UNRELATED_SENTINEL", prompt)

    def test_long_explanation_requires_clean_content_in_original_order(self):
        clean = ("三个检查项。首先按图形位置查找，把重复、偏移、浅灰色的标签先标成背景，"
                 "只保存有效标签。后续检查有没有缺的，再对清单做二次读取，"
                 "包含长度、宽度这类带小数点、斜杠的内容，再逐项比对。")
        self.assertEqual(self.assess_chinese("explanation_long_cleanup", clean), (True, True))
        fixture = evaluation.CHINESE_BY_ID["chinese_explanation_long_cleanup"]
        wrong = [fixture["input"], clean.replace("三个", "四个"), clean.replace("只保存", "保存"),
                 clean.replace("偏移、", ""), clean.replace("小数点", "."),
                 clean.replace("长度、宽度", "长度啊、宽度啊"), clean + "第二项检查颜色。",
                 clean.replace("先标成背景", "先逐项比对").replace("再逐项比对", "再标成背景")]
        for text in wrong:
            with self.subTest(text=text):
                self.assertEqual(self.assess_chinese("explanation_long_cleanup", text), (True, False))
        self.assertEqual(self.assess_chinese("explanation_long_cleanup", clean, correction=True), (True, False))

    def test_step_cleanup_keeps_each_action_and_does_not_repeat_connectors(self):
        clean = "先打开示例，再检查标注，导出清单，再和上一版比对。"
        self.assertEqual(self.assess_chinese("explanation_step_sequence", clean), (True, True))
        for text in ["先打开示例，再导出清单，检查标注，再和上一版比对。",
                     "先打开示例，再检查标注，再和上一版比对。",
                     "先打开示例，然后检查标注，然后导出清单，然后和上一版比对。"]:
            self.assertEqual(self.assess_chinese("explanation_step_sequence", text), (True, False))

    def test_first_plan_is_not_expanded_into_unspoken_alternatives(self):
        clean = "有五种备选做法。首先把重复、偏移的标签标出来，只保存正常标签，后续再检查一遍，别的做法还没说。"
        self.assertEqual(self.assess_chinese("explanation_first_plan_only", clean), (True, True))
        self.assertEqual(self.assess_chinese("explanation_first_plan_only", clean + "第二种是删除标签。"), (True, False))
        case = next(item for item in evaluation.CHINESE_CASES if item[0] == "chinese_explanation_first_plan_only")
        content = json.dumps({"mode": "list", "intro": "有五种备选做法", "items": [
            "首先把重复、偏移的标签标出来", "只保存正常标签", "后续再检查一遍"],
            "outro": "别的做法还没说", "correction_applied": False})
        self.assertEqual(evaluation.assess(content, case), (True, False))

    def test_enumeration_fillers_do_not_authorize_deleting_meaningful_particles(self):
        self.assertEqual(self.assess_chinese("explanation_enumeration_particles", "这次只检查长度、宽度、面积，别改单位。"), (True, True))
        self.assertEqual(self.assess_chinese("explanation_enumeration_particles", "这次只检查长度啊、宽度啊、面积啊，别改单位。"), (True, False))
        for name, raw, deleted in [
            ("explanation_meaningful_particles", "你先别删啊，这个我还要用呢。", "你先别删，这个我还要用。"),
            ("explanation_surprised_question", "啊？你说的是那个标注吗？", "你说的是那个标注吗？"),
            ("explanation_verbatim_particles", "请逐字保留“长度啊、宽度啊、后面呢”。", "请逐字保留“长度、宽度、后面”。"),
            ("explanation_contrasting_demonstratives", "把这些标注留下，那些标注别动，不是全部删除。", "把标注留下，标注别动，不是全部删除。"),
        ]:
            with self.subTest(name=name):
                self.assertEqual(self.assess_chinese(name, raw), (True, True))
                self.assertEqual(self.assess_chinese(name, deleted), (True, False))

    def test_numeric_commas_and_decimal_points_survive_prose_normalization(self):
        clean = "先校对清单，再核对长度、宽度，数值是0.75和1,024.50，单位还是毫米。"
        self.assertEqual(self.assess_chinese("explanation_numeric_facts", clean), (True, True))
        for changed in ["1024.50", "1，024.50", "1X024Y50", "1,02450"]:
            self.assertEqual(self.assess_chinese("explanation_numeric_facts", clean.replace("1,024.50", changed)), (True, False))
        self.assertEqual(self.assess_chinese("explanation_numeric_facts", clean.replace("0.75", "075")), (True, False))

    def test_particle_cleanup_includes_enumeration_and_sentence_tails(self):
        for name, clean, unclean in [
            ("particle_enumeration_ya", "这次只核对数量、金额，先别改单位。", "这次只核对数量呀、金额呀，先别改单位。"),
            ("particle_enumeration_mixed", "先检查长度、宽度、面积，再检查单位。", "先检查长度呀、宽度啊、面积啦，再检查单位。"),
            ("particle_tail_ma", "这几份样例大致相同，我们先核对数字。", "这几份样例大致相同嘛，我们先核对数字。"),
            ("particle_topic_ne", "这几个参数，我们先核对一下，别改默认值。", "这几个参数呢，我们先核对一下，别改默认值。"),
        ]:
            with self.subTest(name=name):
                self.assertEqual(self.assess_chinese(name, clean), (True, True))
                self.assertEqual(self.assess_chinese(name, unclean), (True, False))
                self.assertEqual(self.assess_chinese(name, clean, correction=True), (True, False))
        self.assertEqual(self.assess_chinese("particle_tail_ma", "这几份样例相同，我们先核对数字。"), (True, False))
        self.assertEqual(self.assess_chinese("particle_enumeration_ya", "这次核对数量、金额，先别改单位。"), (True, False))

    def test_particle_candidates_keep_responses_tone_and_word_characters(self):
        for name, raw, deleted in [
            ("particle_reply_ya", "好呀，就按这个方案来。", "好，就按这个方案来。"),
            ("particle_reminder_ya", "先别关呀，我还没保存呢。", "先别关，我还没保存。"),
            ("particle_question_ne", "为什么呢？", "为什么？"),
            ("particle_uncertainty_ba", "可能吧，我还没确认。", "我已经确认。"),
            ("particle_reminder_ma", "别急嘛，等我看完。", "别急，等我看完。"),
            ("particle_verbatim", "请逐字保留“参数呀、数值嘛、后面呢”。", "请逐字保留“参数、数值、后面”。"),
            ("particle_within_word", "你干嘛把源码删了？", "你干把源码删了？"),
            ("particle_discussing_character", "这句话里的“呀”是被讨论的字，不是让你删掉。", "这句话里的是被讨论的字，不是让你删掉。"),
        ]:
            with self.subTest(name=name):
                self.assertEqual(self.assess_chinese(name, raw), (True, True))
                self.assertEqual(self.assess_chinese(name, deleted), (True, False))

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
