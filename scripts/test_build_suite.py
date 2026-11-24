"""Tests for build-suite.py. Run from the repository root:

    python3 -m unittest discover -s scripts -p 'test_*.py'
"""
import contextlib
import importlib.util
import io
import os
import tempfile
import unittest

_SPEC = importlib.util.spec_from_file_location(
    "build_suite", os.path.join(os.path.dirname(os.path.abspath(__file__)), "build-suite.py"))
build_suite = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(build_suite)

BASE_ARGS = ["--namespace", "crew-demo", "--crew-ref", "demo", "--name", "baseline", "--iterations", "2"]


def write(directory, name, content):
    with open(os.path.join(directory, name), "w", encoding="utf-8") as f:
        f.write(content)


def run_main(argv):
    """Run main and return (exit code, stdout, stderr)."""
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = build_suite.main(argv)
    return code, out.getvalue(), err.getvalue()


class IsScenarioTest(unittest.TestCase):
    def test_adl_and_md_are_scenarios(self):
        self.assertTrue(build_suite.is_scenario("smoke.adl"))
        self.assertTrue(build_suite.is_scenario("smoke.md"))

    def test_readme_is_documentation(self):
        self.assertFalse(build_suite.is_scenario("README.md"))

    def test_other_files_are_ignored(self):
        for name in ("build-suite.py", "values.yaml", "notes.txt", "smoke.adl.bak", "adl", "md"):
            with self.subTest(name=name):
                self.assertFalse(build_suite.is_scenario(name))


class ScenariosTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = self._tmp.name

    def tearDown(self):
        self._tmp.cleanup()

    def test_picks_up_adl_and_md_sorted_and_skips_the_rest(self):
        write(self.dir, "b-prose.md", "WHEN b\n")
        write(self.dir, "a-adl.adl", "WHEN a\n\n\n")
        write(self.dir, "README.md", "docs")
        write(self.dir, "helper.py", "print()")
        write(self.dir, "c.yaml", "k: v")
        self.assertEqual(build_suite.scenarios(self.dir), [("a-adl", "WHEN a"), ("b-prose", "WHEN b")])

    def test_empty_directory_has_no_scenarios(self):
        write(self.dir, "README.md", "docs")
        self.assertEqual(build_suite.scenarios(self.dir), [])

    def test_missing_directory_raises(self):
        with self.assertRaises(FileNotFoundError):
            build_suite.scenarios(os.path.join(self.dir, "absent"))


class IndentTest(unittest.TestCase):
    def test_indents_every_non_empty_line(self):
        self.assertEqual(build_suite.indent("a\n  b", 4), "    a\n      b")

    def test_empty_lines_stay_empty(self):
        self.assertEqual(build_suite.indent("a\n\nb", 2), "  a\n\n  b")

    def test_empty_text(self):
        self.assertEqual(build_suite.indent("", 8), "")


class YamlQuoteTest(unittest.TestCase):
    def test_plain_text(self):
        self.assertEqual(build_suite.yaml_quote("READ-query baseline"), "'READ-query baseline'")

    def test_apostrophe_is_doubled(self):
        self.assertEqual(build_suite.yaml_quote("crew's baseline"), "'crew''s baseline'")

    def test_double_quotes_and_backslashes_are_literal(self):
        self.assertEqual(build_suite.yaml_quote('say "hi" C:\\x'), "'say \"hi\" C:\\x'")

    def test_empty(self):
        self.assertEqual(build_suite.yaml_quote(""), "''")


class RenderTest(unittest.TestCase):
    def args(self, *extra):
        return build_suite.parse_args(["fitness"] + BASE_ARGS + list(extra))

    def test_full_manifest(self):
        scn = [("one", "WHEN x\n\nTHEN y"), ("two", "ASSERT z")]
        expected = (
            "apiVersion: kubemoot.ai/v1alpha1\n"
            "kind: CrewFitnessSuite\n"
            "metadata:\n"
            "  name: baseline\n"
            "  namespace: crew-demo\n"
            "spec:\n"
            "  crewRef: demo\n"
            "  description: 'the crew''s run'\n"
            "  iterations: 2\n"
            "  concurrency: 1\n"
            "  perIterationTimeout: 5m\n"
            "  artifactRetention: 24h\n"
            "  scripts:\n"
            "    - testRef: one\n"
            "      testContent: |\n"
            "        WHEN x\n"
            "\n"
            "        THEN y\n"
            "    - testRef: two\n"
            "      testContent: |\n"
            "        ASSERT z"
        )
        args = self.args("--description", "the crew's run", "--per-iteration-timeout", "5m",
                         "--artifact-retention", "24h")
        self.assertEqual(build_suite.render(scn, args), expected)

    def test_no_description_line_without_description(self):
        rendered = build_suite.render([("one", "x")], self.args())
        self.assertNotIn("description:", rendered)
        self.assertIn("  perIterationTimeout: 10m\n  artifactRetention: 720h", rendered)


class MainTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = self._tmp.name

    def tearDown(self):
        self._tmp.cleanup()

    def test_prints_manifest_and_count(self):
        write(self.dir, "one.adl", "WHEN x\n")
        write(self.dir, "two.md", "When y.\n")
        code, out, err = run_main([self.dir] + BASE_ARGS)
        self.assertEqual(code, 0)
        self.assertEqual(err, "assembling 2 scenarios x 2 = 4 runs\n")
        self.assertIn("    - testRef: one\n", out)
        self.assertIn("    - testRef: two\n", out)
        self.assertTrue(out.endswith("        When y.\n"))

    def test_missing_directory_is_an_error(self):
        code, out, err = run_main([os.path.join(self.dir, "absent")] + BASE_ARGS)
        self.assertEqual(code, 2)
        self.assertEqual(out, "")
        self.assertIn("fitness directory not found", err)

    def test_zero_scenarios_is_an_error(self):
        write(self.dir, "README.md", "docs")
        code, out, err = run_main([self.dir] + BASE_ARGS)
        self.assertEqual(code, 1)
        self.assertEqual(out, "")
        self.assertIn("no .adl or .md scenarios", err)

    def test_multi_line_description_is_rejected(self):
        with self.assertRaises(SystemExit) as ctx, contextlib.redirect_stderr(io.StringIO()) as err:
            build_suite.parse_args([self.dir] + BASE_ARGS + ["--description", "one\ntwo"])
        self.assertEqual(ctx.exception.code, 2)
        self.assertIn("must be a single line", err.getvalue())

    def test_required_arguments(self):
        for missing in ("--namespace", "--crew-ref", "--name", "--iterations"):
            argv = list(BASE_ARGS)
            i = argv.index(missing)
            del argv[i:i + 2]
            with self.subTest(missing=missing), self.assertRaises(SystemExit), \
                    contextlib.redirect_stderr(io.StringIO()):
                build_suite.parse_args([self.dir] + argv)

    def test_iterations_must_be_an_integer(self):
        argv = [self.dir] + BASE_ARGS[:-1] + ["ten"]
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            build_suite.parse_args(argv)


class TierTest(unittest.TestCase):
    SCN = (
        ("a", 'DEFINE CONST TIERS AS "smoke standard"\nDEFINE CONST QUESTION AS "q"'),
        ("b", 'DEFINE CONST TIERS AS "standard"'),
        ("c", 'DEFINE CONST TIERS AS "Smoke, standard"'),
        ("d", 'DEFINE CONST QUESTION AS "q"'),
    )

    def test_tiers_of_a_scenario(self):
        self.assertEqual(build_suite.scenario_tiers(self.SCN[0][1]), ["smoke", "standard"])
        self.assertEqual(build_suite.scenario_tiers(self.SCN[2][1]), ["smoke", "standard"])
        self.assertEqual(build_suite.scenario_tiers("DESCRIPTION none"), [])
        self.assertEqual(build_suite.scenario_tiers('DEFINE CONST TIERS AS ""'), [])

    def test_select_each_tier(self):
        def names(tier):
            return [ref for ref, _ in build_suite.select_tier(self.SCN, tier)]

        self.assertEqual(names("smoke"), ["a", "c"])
        self.assertEqual(names("standard"), ["a", "b", "c"])
        self.assertEqual(names("full"), ["a", "b", "c", "d"])

    def test_an_unknown_label_is_refused_not_dropped(self):
        for tier in ("smoke", "standard"):
            with self.subTest(tier=tier), self.assertRaises(ValueError) as ctx:
                build_suite.select_tier([("x", 'DEFINE CONST TIERS AS "smok"')], tier)
            self.assertIn("unknown tier 'smok'", str(ctx.exception))
        with self.assertRaises(ValueError):
            build_suite.select_tier([("x", 'DEFINE CONST TIERS AS "full"')], "smoke")

    def test_full_ignores_labels(self):
        self.assertEqual(len(build_suite.select_tier([("x", 'DEFINE CONST TIERS AS "nonsense"')], "full")), 1)


class MainTierTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = self._tmp.name
        write(self.dir, "a.adl", 'DEFINE CONST TIERS AS "smoke standard"\n')
        write(self.dir, "b.adl", 'DEFINE CONST TIERS AS "standard"\n')
        write(self.dir, "c.adl", "DESCRIPTION untagged\n")

    def tearDown(self):
        self._tmp.cleanup()

    def test_tier_includes_only_its_scenarios(self):
        code, out, err = run_main([self.dir] + BASE_ARGS + ["--tier", "smoke"])
        self.assertEqual(code, 0)
        self.assertEqual(err, "assembling 1 scenarios x 2 = 2 runs\n")
        self.assertIn("    - testRef: a\n", out)
        self.assertNotIn("testRef: b", out)

    def test_default_is_every_scenario(self):
        code, _out, err = run_main([self.dir] + BASE_ARGS)
        self.assertEqual(code, 0)
        self.assertEqual(err, "assembling 3 scenarios x 2 = 6 runs\n")

    def test_a_tier_nothing_names_is_an_error(self):
        for name in ("a.adl", "b.adl"):
            os.remove(os.path.join(self.dir, name))
        code, out, err = run_main([self.dir] + BASE_ARGS + ["--tier", "smoke"])
        self.assertEqual((code, out), (1, ""))
        self.assertIn("names tier smoke", err)

    def test_an_unknown_label_is_an_error(self):
        write(self.dir, "d.adl", 'DEFINE CONST TIERS AS "smok"\n')
        code, out, err = run_main([self.dir] + BASE_ARGS + ["--tier", "standard"])
        self.assertEqual((code, out), (1, ""))
        self.assertIn("unknown tier 'smok'", err)

    def test_an_unknown_tier_is_refused_by_the_parser(self):
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            build_suite.parse_args([self.dir] + BASE_ARGS + ["--tier", "weekly"])
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            build_suite.parse_args([self.dir] + BASE_ARGS + ["--tier", ""])


if __name__ == "__main__":
    unittest.main()
