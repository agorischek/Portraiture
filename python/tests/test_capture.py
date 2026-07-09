from __future__ import annotations

import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

from portraiture import (
    CaptureInterpreter,
    Portraitist,
    PortraitistOptions,
    capture,
    portraitist,
)

posix_only = unittest.skipUnless(os.name == "posix", "requires a POSIX platform")


class CaptureTestCase(unittest.TestCase):
    def make_temp_dir(self, prefix: str = "portraiture-test-") -> Path:
        directory = tempfile.TemporaryDirectory(prefix=prefix)
        self.addCleanup(directory.cleanup)
        return Path(directory.name)

    def write_temp_script(self, name: str, contents: str, *, executable: bool = False) -> Path:
        path = self.make_temp_dir() / name
        path.write_text(contents)
        if executable:
            path.chmod(0o755)
        return path


class CaptureTests(CaptureTestCase):
    def test_command_captures_stdout(self) -> None:
        result = portraitist.capture_command(f"{sys.executable} -c \"print('hello')\"")

        self.assertTrue(result.ok)
        if result.ok:
            self.assertEqual(result.stdout, "hello\n")
            self.assertEqual(result.value, "hello\n")
            self.assertEqual(result.target.kind, "command")

    def test_capture_command_facade_delegates_to_default_portraitist(self) -> None:
        result = capture.command(f"{sys.executable} -c \"print('facade')\"")

        self.assertTrue(result.ok)
        if result.ok:
            self.assertEqual(result.value, "facade\n")

    def test_script_accepts_parser(self) -> None:
        result = portraitist.capture_script(
            sys.executable,
            ["-c", "import json; print(json.dumps({'hostname': 'local'}))"],
            parser=json.loads,
        )

        self.assertTrue(result.ok)
        if result.ok:
            self.assertEqual(result.value["hostname"], "local")
            self.assertEqual(result.target.kind, "script")

    def test_capture_script_facade_delegates_to_default_portraitist(self) -> None:
        result = capture.script(sys.executable, ["-c", "print('facade')"])

        self.assertTrue(result.ok)
        if result.ok:
            self.assertEqual(result.value, "facade\n")

    def test_script_supports_explicit_interpreter(self) -> None:
        script = self.write_temp_script(
            "explicit.portraiturepy",
            "import sys\nprint(sys.argv[1])\n",
        )

        result = portraitist.capture_script(
            str(script),
            ["via-interpreter"],
            interpreter=sys.executable,
        )

        self.assertTrue(result.ok)
        if result.ok:
            self.assertEqual(result.value, "via-interpreter\n")
            self.assertEqual(result.target.command, sys.executable)
            self.assertEqual(result.target.script, str(script))

    def test_portraitist_can_use_default_interpreters_by_extension(self) -> None:
        script = self.write_temp_script(
            "default.portraiturepy",
            "import sys\nprint(sys.argv[1])\n",
        )
        custom = Portraitist(interpreters={"portraiturepy": sys.executable})

        result = custom.capture_script(str(script), ["from-default"])

        self.assertTrue(result.ok)
        if result.ok:
            self.assertEqual(result.value, "from-default\n")
            self.assertEqual(result.target.command, sys.executable)
            self.assertEqual(result.target.script, str(script))

    def test_process_passes_literal_args_without_shell(self) -> None:
        result = portraitist.capture_process(
            sys.executable,
            ["-c", "import sys; print(sys.argv[1])", "hello; echo nope"],
        )

        self.assertTrue(result.ok)
        if result.ok:
            self.assertEqual(result.value, "hello; echo nope\n")
            self.assertEqual(result.target.kind, "process")

    def test_capture_process_facade_delegates_to_default_portraitist(self) -> None:
        result = capture.process(sys.executable, ["-c", "print('facade')"])

        self.assertTrue(result.ok)
        if result.ok:
            self.assertEqual(result.value, "facade\n")

    def test_parser_reads_stdout_by_default(self) -> None:
        result = portraitist.capture_script(
            sys.executable,
            [
                "-c",
                "import json, sys; print('warn', file=sys.stderr); print(json.dumps({'ok': True}))",
            ],
            parser=json.loads,
        )

        self.assertTrue(result.ok)
        if result.ok:
            self.assertEqual(result.stderr, "warn\n")
            self.assertEqual(result.value["ok"], True)

    def test_parse_input_can_parse_combined_output(self) -> None:
        result = portraitist.capture_process(
            sys.executable,
            ["-c", "import json; print(json.dumps({'ok': True}))"],
            parser=json.loads,
            parse_input="combined",
        )

        self.assertTrue(result.ok)
        if result.ok:
            self.assertEqual(result.value["ok"], True)

    def test_parser_failure_returns_parse_error(self) -> None:
        result = portraitist.capture_process(
            sys.executable,
            ["-c", "print('not-json')"],
            parser=json.loads,
        )

        self.assertFalse(result.ok)
        if not result.ok:
            self.assertEqual(result.error.kind, "parse")
            self.assertEqual(result.stdout, "not-json\n")

    def test_stderr_can_fail_result(self) -> None:
        result = portraitist.capture_script(
            sys.executable,
            ["-c", "import sys; print('warn', file=sys.stderr)"],
            stderr="fail",
        )

        self.assertFalse(result.ok)
        if not result.ok:
            self.assertEqual(result.error.kind, "stderr")
            self.assertEqual(result.stderr, "warn\n")

    def test_nonzero_exit_fails_by_default(self) -> None:
        result = portraitist.capture_script(sys.executable, ["-c", "print('before'); raise SystemExit(7)"])

        self.assertFalse(result.ok)
        if not result.ok:
            self.assertEqual(result.error.kind, "exit")
            self.assertEqual(result.exit_code, 7)
            self.assertEqual(result.stdout, "before\n")

    def test_nonzero_exit_can_be_collected_as_successful_data(self) -> None:
        result = portraitist.capture_script(
            sys.executable,
            ["-c", "print('data'); raise SystemExit(7)"],
            fail_on_nonzero_exit=False,
        )

        self.assertTrue(result.ok)
        if result.ok:
            self.assertEqual(result.exit_code, 7)
            self.assertEqual(result.value, "data\n")

    def test_timeout_returns_timeout_failure(self) -> None:
        result = portraitist.capture_process(
            sys.executable,
            ["-c", "import time; time.sleep(5)"],
            timeout_ms=50,
        )

        self.assertFalse(result.ok)
        if not result.ok:
            self.assertEqual(result.error.kind, "timeout")

    def test_spawn_error_returns_spawn_failure(self) -> None:
        result = portraitist.capture_process("__portraiture_missing_executable__")

        self.assertFalse(result.ok)
        if not result.ok:
            self.assertEqual(result.error.kind, "spawn")

    def test_stdin_is_sent_to_process(self) -> None:
        result = portraitist.capture_process(
            sys.executable,
            ["-c", "import sys; print(sys.stdin.read())"],
            stdin="hello stdin",
        )

        self.assertTrue(result.ok)
        if result.ok:
            self.assertEqual(result.value, "hello stdin\n")

    def test_logger_receives_lifecycle_and_stream_events(self) -> None:
        events: list[str] = []
        result = portraitist.capture_process(
            sys.executable,
            ["-c", "import sys; print('out'); print('err', file=sys.stderr)"],
            logger=lambda event: events.append(event["type"]),
        )

        self.assertTrue(result.ok)
        self.assertEqual(events[0], "start")
        self.assertEqual(events[-1], "finish")
        self.assertIn("stdout", events)
        self.assertIn("stderr", events)

    def test_logger_exceptions_do_not_change_capture_result(self) -> None:
        def logger(_event: object) -> None:
            raise RuntimeError("logger failed")

        result = portraitist.capture_process(
            sys.executable,
            ["-c", "print('ok')"],
            logger=logger,
        )

        self.assertTrue(result.ok)
        if result.ok:
            self.assertEqual(result.value, "ok\n")

    def test_portraitist_instances_are_independent(self) -> None:
        custom = Portraitist()
        result = custom.capture_process(sys.executable, ["-c", "print('ok')"])

        self.assertTrue(result.ok)
        if result.ok:
            self.assertEqual(result.value, "ok\n")

    def test_portraitist_can_set_default_working_directory(self) -> None:
        directory = self.make_temp_dir("portraiture-cwd-")
        (directory / "marker.txt").write_text("default")
        custom = Portraitist(cwd=str(directory))
        result = custom.capture_process(
            sys.executable,
            ["-c", "from pathlib import Path; print(Path('marker.txt').read_text(), end='')"],
        )

        self.assertTrue(result.ok)
        if result.ok:
            self.assertEqual(result.value, "default")

    def test_portraitist_options_can_set_default_working_directory(self) -> None:
        directory = self.make_temp_dir("portraiture-cwd-options-")
        (directory / "marker.txt").write_text("options")
        custom = Portraitist(PortraitistOptions(cwd=str(directory)))
        result = custom.capture_process(
            sys.executable,
            ["-c", "from pathlib import Path; print(Path('marker.txt').read_text(), end='')"],
        )

        self.assertTrue(result.ok)
        if result.ok:
            self.assertEqual(result.value, "options")

    def test_per_call_cwd_overrides_portraitist_default(self) -> None:
        default_directory = self.make_temp_dir("portraiture-cwd-default-")
        override_directory = self.make_temp_dir("portraiture-cwd-override-")
        (default_directory / "marker.txt").write_text("default")
        (override_directory / "marker.txt").write_text("override")
        custom = Portraitist(cwd=str(default_directory))
        result = custom.capture_process(
            sys.executable,
            ["-c", "from pathlib import Path; print(Path('marker.txt').read_text(), end='')"],
            cwd=str(override_directory),
        )

        self.assertTrue(result.ok)
        if result.ok:
            self.assertEqual(result.value, "override")


class EnvironmentTests(CaptureTestCase):
    ECHO_VARS = (
        "import os; "
        "print(os.environ.get('PORTRAITURE_A', '')); "
        "print(os.environ.get('PORTRAITURE_B', '')); "
        "print('has-path' if os.environ.get('PATH') else 'no-path')"
    )

    def test_per_call_env_augments_parent_environment(self) -> None:
        result = portraitist.capture_process(
            sys.executable,
            ["-c", self.ECHO_VARS],
            env={"PORTRAITURE_A": "per-call"},
        )

        self.assertTrue(result.ok)
        if result.ok:
            self.assertEqual(result.stdout, "per-call\n\nhas-path\n")

    def test_constructor_default_env_augments_parent_environment(self) -> None:
        custom = Portraitist(env={"PORTRAITURE_A": "default"})
        result = custom.capture_process(sys.executable, ["-c", self.ECHO_VARS])

        self.assertTrue(result.ok)
        if result.ok:
            self.assertEqual(result.stdout, "default\n\nhas-path\n")

    def test_per_call_env_overlays_constructor_default_env(self) -> None:
        custom = Portraitist(env={"PORTRAITURE_A": "default", "PORTRAITURE_B": "kept"})
        result = custom.capture_process(
            sys.executable,
            ["-c", self.ECHO_VARS],
            env={"PORTRAITURE_A": "override"},
        )

        self.assertTrue(result.ok)
        if result.ok:
            self.assertEqual(result.stdout, "override\nkept\nhas-path\n")

    def test_env_none_clears_constructor_default_env(self) -> None:
        custom = Portraitist(env={"PORTRAITURE_A": "default"})
        result = custom.capture_process(
            sys.executable,
            ["-c", self.ECHO_VARS],
            env=None,
        )

        self.assertTrue(result.ok)
        if result.ok:
            self.assertEqual(result.stdout, "\n\nhas-path\n")


class DefaultsAndOverridesTests(CaptureTestCase):
    def test_constructor_stderr_default_and_per_call_override(self) -> None:
        custom = Portraitist(stderr="fail")
        code = ["-c", "import sys; print('warn', file=sys.stderr)"]

        failing = custom.capture_process(sys.executable, code)
        self.assertFalse(failing.ok)
        if not failing.ok:
            self.assertEqual(failing.error.kind, "stderr")

        overridden = custom.capture_process(sys.executable, code, stderr="capture")
        self.assertTrue(overridden.ok)

    def test_constructor_timeout_default_and_per_call_override(self) -> None:
        custom = Portraitist(timeout_ms=100)
        code = ["-c", "import time; time.sleep(0.5); print('slow')"]

        failing = custom.capture_process(sys.executable, code)
        self.assertFalse(failing.ok)
        if not failing.ok:
            self.assertEqual(failing.error.kind, "timeout")

        overridden = custom.capture_process(sys.executable, code, timeout_ms=10_000)
        self.assertTrue(overridden.ok)

    def test_per_call_timeout_none_clears_constructor_default(self) -> None:
        custom = Portraitist(timeout_ms=100)
        result = custom.capture_process(
            sys.executable,
            ["-c", "import time; time.sleep(0.3); print('done')"],
            timeout_ms=None,
        )

        self.assertTrue(result.ok)
        if result.ok:
            self.assertEqual(result.value, "done\n")

    def test_constructor_fail_on_nonzero_exit_default_and_per_call_override(self) -> None:
        custom = Portraitist(fail_on_nonzero_exit=False)
        code = ["-c", "raise SystemExit(3)"]

        collected = custom.capture_process(sys.executable, code)
        self.assertTrue(collected.ok)
        if collected.ok:
            self.assertEqual(collected.exit_code, 3)

        overridden = custom.capture_process(sys.executable, code, fail_on_nonzero_exit=True)
        self.assertFalse(overridden.ok)
        if not overridden.ok:
            self.assertEqual(overridden.error.kind, "exit")

    def test_constructor_stdin_default_and_per_call_override_and_clear(self) -> None:
        custom = Portraitist(stdin="from-default")
        code = ["-c", "import sys; print(sys.stdin.read(), end='')"]

        default_result = custom.capture_process(sys.executable, code)
        self.assertTrue(default_result.ok)
        if default_result.ok:
            self.assertEqual(default_result.value, "from-default")

        overridden = custom.capture_process(sys.executable, code, stdin="per-call")
        self.assertTrue(overridden.ok)
        if overridden.ok:
            self.assertEqual(overridden.value, "per-call")

        cleared = custom.capture_process(sys.executable, code, stdin=None)
        self.assertTrue(cleared.ok)
        if cleared.ok:
            self.assertEqual(cleared.value, "")

    def test_constructor_logger_default_and_per_call_override_and_clear(self) -> None:
        default_events: list[str] = []
        per_call_events: list[str] = []
        custom = Portraitist(logger=lambda event: default_events.append(event["type"]))

        custom.capture_process(sys.executable, ["-c", "print('a')"])
        self.assertIn("start", default_events)
        self.assertIn("finish", default_events)

        default_count = len(default_events)
        custom.capture_process(
            sys.executable,
            ["-c", "print('b')"],
            logger=lambda event: per_call_events.append(event["type"]),
        )
        self.assertEqual(len(default_events), default_count)
        self.assertIn("finish", per_call_events)

        custom.capture_process(sys.executable, ["-c", "print('c')"], logger=None)
        self.assertEqual(len(default_events), default_count)

    def test_constructor_parse_input_default(self) -> None:
        custom = Portraitist(parse_input="stderr")
        result = custom.capture_process(
            sys.executable,
            ["-c", "import sys, json; print(json.dumps({'from': 'stderr'}), file=sys.stderr)"],
            parser=json.loads,
        )

        self.assertTrue(result.ok)
        if result.ok:
            self.assertEqual(result.value["from"], "stderr")

    def test_keyword_arguments_override_supplied_options(self) -> None:
        options_directory = self.make_temp_dir("portraiture-options-")
        kwargs_directory = self.make_temp_dir("portraiture-kwargs-")
        (options_directory / "marker.txt").write_text("options")
        (kwargs_directory / "marker.txt").write_text("kwargs")
        custom = Portraitist(
            PortraitistOptions(cwd=str(options_directory)),
            cwd=str(kwargs_directory),
        )

        result = custom.capture_process(
            sys.executable,
            ["-c", "from pathlib import Path; print(Path('marker.txt').read_text(), end='')"],
        )

        self.assertTrue(result.ok)
        if result.ok:
            self.assertEqual(result.value, "kwargs")

    def test_constructor_keyword_none_clears_options_default(self) -> None:
        custom = Portraitist(PortraitistOptions(timeout_ms=100), timeout_ms=None)
        result = custom.capture_process(
            sys.executable,
            ["-c", "import time; time.sleep(0.3); print('done')"],
        )

        self.assertTrue(result.ok)
        if result.ok:
            self.assertEqual(result.value, "done\n")


class ParseInputTests(CaptureTestCase):
    def test_parse_input_stderr_selects_stderr(self) -> None:
        result = portraitist.capture_process(
            sys.executable,
            ["-c", "import sys; print('noise'); print('picked', file=sys.stderr)"],
            parser=str.strip,
            parse_input="stderr",
        )

        self.assertTrue(result.ok)
        if result.ok:
            self.assertEqual(result.value, "picked")

    def test_parse_input_explicit_stdout_ignores_stderr(self) -> None:
        result = portraitist.capture_process(
            sys.executable,
            ["-c", "import sys; print('picked'); print('noise', file=sys.stderr)"],
            parser=str.strip,
            parse_input="stdout",
        )

        self.assertTrue(result.ok)
        if result.ok:
            self.assertEqual(result.value, "picked")

    def test_value_without_parser_is_combined_output(self) -> None:
        result = portraitist.capture_process(
            sys.executable,
            ["-c", "import sys; print('out'); sys.stdout.flush(); print('err', file=sys.stderr)"],
        )

        self.assertTrue(result.ok)
        if result.ok:
            self.assertEqual(result.value, result.output)
            self.assertIn("out\n", result.value)
            self.assertIn("err\n", result.value)


class ShellBehaviorTests(CaptureTestCase):
    @posix_only
    def test_capture_command_uses_shell_semantics_by_default(self) -> None:
        result = portraitist.capture_command(
            'echo "$PORTRAITURE_SHELL_VAR"',
            env={"PORTRAITURE_SHELL_VAR": "expanded"},
        )

        self.assertTrue(result.ok)
        if result.ok:
            self.assertEqual(result.stdout, "expanded\n")

    def test_capture_command_without_shell_splits_command_string(self) -> None:
        result = portraitist.capture_command(
            f'"{sys.executable}" -c "import sys; print(sys.argv[1])" \'$PORTRAITURE_SHELL_VAR\'',
            shell=False,
            env={"PORTRAITURE_SHELL_VAR": "expanded"},
        )

        self.assertTrue(result.ok)
        if result.ok:
            # No shell: quoting is honored but no expansion happens.
            self.assertEqual(result.stdout, "$PORTRAITURE_SHELL_VAR\n")

    def test_empty_command_without_shell_is_a_spawn_failure(self) -> None:
        result = portraitist.capture_command("   ", shell=False)

        self.assertFalse(result.ok)
        if not result.ok:
            self.assertEqual(result.error.kind, "spawn")

    @posix_only
    def test_shell_process_arguments_are_quoted_not_injected(self) -> None:
        # Regression for B1: an argument containing shell metacharacters
        # must be passed literally, not executed by the shell.
        result = portraitist.capture_process(
            sys.executable,
            ["-c", "import sys; print(sys.argv[1])", "safe; echo INJECTED"],
            shell=True,
        )

        self.assertTrue(result.ok)
        if result.ok:
            self.assertEqual(result.stdout, "safe; echo INJECTED\n")

    @posix_only
    def test_constructor_shell_default_and_per_call_override(self) -> None:
        custom = Portraitist(shell=False)
        env = {"PORTRAITURE_SHELL_VAR": "expanded"}

        literal = custom.capture_command('echo "$PORTRAITURE_SHELL_VAR"', env=env)
        self.assertTrue(literal.ok)
        if literal.ok:
            self.assertEqual(literal.stdout, "$PORTRAITURE_SHELL_VAR\n")

        expanded = custom.capture_command('echo "$PORTRAITURE_SHELL_VAR"', env=env, shell=True)
        self.assertTrue(expanded.ok)
        if expanded.ok:
            self.assertEqual(expanded.stdout, "expanded\n")


class TimeoutTests(CaptureTestCase):
    def test_output_captured_before_timeout_is_preserved(self) -> None:
        result = portraitist.capture_process(
            sys.executable,
            ["-c", "import sys, time; print('partial', flush=True); time.sleep(30)"],
            timeout_ms=500,
        )

        self.assertFalse(result.ok)
        if not result.ok:
            self.assertEqual(result.error.kind, "timeout")
            self.assertEqual(result.stdout, "partial\n")

    @posix_only
    def test_timeout_kills_shell_grandchildren_within_bound(self) -> None:
        # Regression for B2: a backgrounded grandchild holding the pipes
        # must not hang the capture past the timeout.
        started = time.monotonic()
        result = portraitist.capture_command("sleep 30 & sleep 30", timeout_ms=200)
        elapsed = time.monotonic() - started

        self.assertFalse(result.ok)
        if not result.ok:
            self.assertEqual(result.error.kind, "timeout")
        self.assertLess(elapsed, 5.0)

    def test_timeout_bounds_call_with_large_unread_stdin(self) -> None:
        # Regression for B3: a child that never reads stdin must not
        # block the caller past the timeout while stdin is being written.
        started = time.monotonic()
        result = portraitist.capture_process(
            sys.executable,
            ["-c", "import time; time.sleep(30)"],
            stdin="x" * (1 << 21),
            timeout_ms=300,
        )
        elapsed = time.monotonic() - started

        self.assertFalse(result.ok)
        if not result.ok:
            self.assertEqual(result.error.kind, "timeout")
        self.assertLess(elapsed, 5.0)

    def test_child_exiting_without_reading_stdin_returns_structured_result(self) -> None:
        result = portraitist.capture_process(
            sys.executable,
            ["-c", "print('ignored stdin')"],
            stdin="x" * (1 << 21),
        )

        self.assertTrue(result.ok)
        if result.ok:
            self.assertEqual(result.value, "ignored stdin\n")


class SignalTests(CaptureTestCase):
    @posix_only
    def test_child_killed_by_signal_reports_signal_not_exit_code(self) -> None:
        result = portraitist.capture_process(
            sys.executable,
            ["-c", "import os, signal; os.kill(os.getpid(), signal.SIGTERM)"],
        )

        self.assertFalse(result.ok)
        if not result.ok:
            self.assertEqual(result.error.kind, "exit")
            self.assertIsNone(result.exit_code)
            self.assertEqual(result.signal, 15)
            self.assertIn("signal 15", result.error.message)


class InterpreterTests(CaptureTestCase):
    SCRIPT_BODY = "import sys\nprint(sys.argv[1])\n"

    def test_interpreter_accepts_sequence_form(self) -> None:
        script = self.write_temp_script("sequence.portraiturepy", self.SCRIPT_BODY)
        result = portraitist.capture_script(
            str(script),
            ["seq-arg"],
            interpreter=[sys.executable, "-u"],
        )

        self.assertTrue(result.ok)
        if result.ok:
            self.assertEqual(result.value, "seq-arg\n")
            self.assertEqual(result.target.command, sys.executable)
            self.assertEqual(result.target.args[0], "-u")

    def test_interpreter_accepts_capture_interpreter_form(self) -> None:
        script = self.write_temp_script("typed.portraiturepy", self.SCRIPT_BODY)
        result = portraitist.capture_script(
            str(script),
            ["typed-arg"],
            interpreter=CaptureInterpreter(command=sys.executable, args=("-u",)),
        )

        self.assertTrue(result.ok)
        if result.ok:
            self.assertEqual(result.value, "typed-arg\n")
            self.assertEqual(result.target.interpreter, CaptureInterpreter(sys.executable, ("-u",)))

    def test_empty_interpreter_sequence_raises_value_error(self) -> None:
        script = self.write_temp_script("empty.portraiturepy", self.SCRIPT_BODY)

        with self.assertRaises(ValueError):
            portraitist.capture_script(str(script), interpreter=[])

    def test_per_call_interpreter_overrides_default_interpreter(self) -> None:
        script = self.write_temp_script("override.portraiturepy", self.SCRIPT_BODY)
        custom = Portraitist(interpreters={".portraiturepy": "__portraiture_wrong_interpreter__"})

        result = custom.capture_script(
            str(script),
            ["overridden"],
            interpreter=sys.executable,
        )

        self.assertTrue(result.ok)
        if result.ok:
            self.assertEqual(result.value, "overridden\n")
            self.assertEqual(result.target.command, sys.executable)

    @posix_only
    def test_script_file_runs_directly_without_interpreter(self) -> None:
        script = self.write_temp_script(
            "direct.sh",
            "#!/bin/sh\necho from-script\n",
            executable=True,
        )

        result = portraitist.capture_script(str(script))

        self.assertTrue(result.ok)
        if result.ok:
            self.assertEqual(result.value, "from-script\n")
            self.assertEqual(result.target.command, str(script))
            self.assertIsNone(result.target.interpreter)


class ResultShapeTests(CaptureTestCase):
    def test_result_exposes_streams_chunks_duration_and_target(self) -> None:
        result = portraitist.capture_process(
            sys.executable,
            [
                "-c",
                "import sys; sys.stdout.write('o1'); sys.stdout.flush(); "
                "sys.stderr.write('e1'); sys.stderr.flush(); "
                "sys.stdout.write('o2')",
            ],
        )

        self.assertTrue(result.ok)
        if result.ok:
            self.assertEqual(result.stdout, "o1o2")
            self.assertEqual(result.stderr, "e1")
            self.assertEqual(result.output, "".join(chunk.text for chunk in result.chunks))
            self.assertEqual(
                {chunk.stream for chunk in result.chunks},
                {"stdout", "stderr"},
            )
            self.assertIsInstance(result.duration_ms, int)
            self.assertGreaterEqual(result.duration_ms, 0)
            self.assertEqual(result.exit_code, 0)
            self.assertIsNone(result.signal)
            self.assertEqual(result.target.kind, "process")
            self.assertEqual(result.target.command, sys.executable)
            self.assertEqual(result.target.args[0], "-c")

    def test_binary_stdin_is_delivered(self) -> None:
        result = portraitist.capture_process(
            sys.executable,
            ["-c", "import sys; data = sys.stdin.buffer.read(); print(len(data), data[:3].hex())"],
            stdin=b"\x00\x01\x02\xff",
        )

        self.assertTrue(result.ok)
        if result.ok:
            self.assertEqual(result.value, "4 000102\n")

    def test_spawn_failure_result_shape_and_logger_events(self) -> None:
        # Regression for B8: spawn failures must still emit the terminal
        # finish event (ok=False) after start.
        events: list[dict] = []
        result = portraitist.capture_process(
            "__portraiture_missing_executable__",
            logger=lambda event: events.append(dict(event)),
        )

        self.assertFalse(result.ok)
        if not result.ok:
            self.assertEqual(result.error.kind, "spawn")
            self.assertEqual(result.stdout, "")
            self.assertEqual(result.stderr, "")
            self.assertEqual(result.output, "")
            self.assertEqual(result.chunks, ())
            self.assertIsNone(result.exit_code)
            self.assertIsNone(result.signal)
            self.assertGreaterEqual(result.duration_ms, 0)
            self.assertEqual(result.target.command, "__portraiture_missing_executable__")

        self.assertEqual([event["type"] for event in events], ["start", "finish"])
        self.assertIs(events[-1]["ok"], False)


class StreamingTests(CaptureTestCase):
    def test_output_streams_before_process_exit(self) -> None:
        # Regression for B5: early flushed output must arrive as its own
        # chunk (and logger event) while the process is still running,
        # instead of one blocking read at process exit.
        events: list[tuple[float, str]] = []

        def logger(event: dict) -> None:
            events.append((time.monotonic(), event["type"]))

        result = portraitist.capture_process(
            sys.executable,
            [
                "-c",
                "import time; print('early', flush=True); time.sleep(0.6); print('late', flush=True)",
            ],
            logger=logger,
        )

        self.assertTrue(result.ok)
        if result.ok:
            stdout_chunks = [chunk for chunk in result.chunks if chunk.stream == "stdout"]
            self.assertGreaterEqual(len(stdout_chunks), 2)
            self.assertEqual(stdout_chunks[0].text, "early\n")

        first_stdout = min(at for at, kind in events if kind == "stdout")
        finish = max(at for at, kind in events if kind == "finish")
        # Timing-tolerant: the first chunk must arrive well before finish.
        self.assertGreater(finish - first_stdout, 0.25)


if __name__ == "__main__":
    unittest.main()
