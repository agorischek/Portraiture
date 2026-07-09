"""Core implementation of the Portraiture capture SDK.

Portraiture runs external commands, processes, and scripts to capture a
portrait of an environment. This module contains the full implementation;
the public API is re-exported from :mod:`portraiture`.

Key semantics (shared across all Portraiture language ports):

- **Environment**: supplied environment variables AUGMENT the parent
  process environment. The effective child environment is ``os.environ``,
  overlaid with the ``Portraitist`` constructor default ``env``, overlaid
  with the per-call ``env``. Pass ``env=None`` per call to clear a
  constructor default and inherit the parent environment unchanged.
- **Value without a parser**: when no ``parser`` is supplied, ``value`` is
  the *combined* output string (stdout and stderr interleaved in arrival
  order). Because arrival order across two pipes is scheduler-dependent,
  the exact interleaving is best-effort and not guaranteed to be stable.
  Use ``result.stdout`` / ``result.stderr`` (or a ``parser``, which reads
  stdout by default) when you need a single stream.
- **Timeouts**: on POSIX the child is started in its own session
  (process group). On timeout the whole group receives ``SIGTERM``, then
  ``SIGKILL`` after a short grace period, so shell grandchildren are
  reaped too. Output captured before the timeout stays on the result.
  Residual limitation: a descendant that creates its *own* session
  escapes the group kill; reader threads are then abandoned after a
  bounded join rather than hanging. On non-POSIX platforms only the
  direct child is killed.
- **Logging**: the logger callable may be invoked concurrently from
  internal reader threads (stdout and stderr are drained in parallel), so
  it must be thread-safe. Logger exceptions never change the capture
  result.
"""

from __future__ import annotations

import os
import shlex
import signal
import subprocess
import threading
import time
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from typing import Any, Final, Generic, Literal, TypedDict, TypeVar, Union, overload

T = TypeVar("T")

CaptureTargetKind = Literal["command", "process", "script"]
CaptureStream = Literal["stdout", "stderr"]
CaptureParseInput = Literal["combined", "stdout", "stderr"]
CaptureStderrPolicy = Literal["capture", "fail"]
CaptureFailureKind = Literal["exit", "parse", "spawn", "stderr", "timeout"]
CaptureParser = Callable[[str], T]


class _UnsetType:
    """Sentinel type for :data:`UNSET`. Falsy; a process-wide singleton."""

    _instance: _UnsetType | None = None

    def __new__(cls) -> _UnsetType:
        if cls._instance is None:
            cls._instance = super().__new__(cls)
        return cls._instance

    def __repr__(self) -> str:
        return "UNSET"

    def __bool__(self) -> Literal[False]:
        return False


UNSET: Final = _UnsetType()
"""Sentinel meaning "no per-call value supplied; use the configured default".

Per-call options default to ``UNSET`` so that explicit ``None`` (or other
falsy values) can *clear* a ``Portraitist`` constructor default. For
example ``timeout_ms=None`` disables a default timeout for one call, and
``env=None`` clears a default environment overlay.
"""


@dataclass(frozen=True)
class CaptureChunk:
    stream: CaptureStream
    text: str


@dataclass(frozen=True)
class CaptureInterpreter:
    command: str
    args: tuple[str, ...]


CaptureInterpreterInput = Union[str, Sequence[str], CaptureInterpreter]


@dataclass(frozen=True)
class CaptureTarget:
    kind: CaptureTargetKind
    command: str
    args: tuple[str, ...]
    script: str | None = None
    interpreter: CaptureInterpreter | None = None


class CaptureStartEvent(TypedDict):
    """Emitted once before the target is launched."""

    type: Literal["start"]
    target: CaptureTarget


class CaptureStdoutEvent(TypedDict):
    """Emitted for each stdout chunk as it arrives (from a reader thread)."""

    type: Literal["stdout"]
    text: str


class CaptureStderrEvent(TypedDict):
    """Emitted for each stderr chunk as it arrives (from a reader thread)."""

    type: Literal["stderr"]
    text: str


class CaptureFinishEvent(TypedDict):
    """Terminal event, emitted exactly once for every capture.

    ``ok`` is ``False`` for every failure kind, including spawn failures.
    """

    type: Literal["finish"]
    ok: bool
    duration_ms: int
    exit_code: int | None
    signal: int | None


CaptureLogEvent = Union[
    CaptureStartEvent, CaptureStdoutEvent, CaptureStderrEvent, CaptureFinishEvent
]

CaptureLogger = Callable[[CaptureLogEvent], None]
"""Capture lifecycle/stream logger.

Thread-safety: stdout and stderr are drained on separate threads, so the
logger may be invoked concurrently. Implementations must be thread-safe.
"""


@dataclass(frozen=True)
class CaptureContext:
    stdout: str
    stderr: str
    output: str
    chunks: tuple[CaptureChunk, ...]
    exit_code: int | None
    signal: int | None
    duration_ms: int


@dataclass(frozen=True)
class CaptureFailure:
    kind: CaptureFailureKind
    message: str
    cause: BaseException | None = None


@dataclass(frozen=True)
class CaptureSuccess(Generic[T]):
    """Successful capture.

    Without a parser, ``value`` is the combined output string (stdout and
    stderr in best-effort arrival order) — see the module docstring for
    the interleaving caveat.
    """

    value: T
    stdout: str
    stderr: str
    output: str
    chunks: tuple[CaptureChunk, ...]
    exit_code: int | None
    signal: int | None
    duration_ms: int
    target: CaptureTarget
    ok: Literal[True] = True


@dataclass(frozen=True)
class CaptureErrorResult:
    error: CaptureFailure
    stdout: str
    stderr: str
    output: str
    chunks: tuple[CaptureChunk, ...]
    exit_code: int | None
    signal: int | None
    duration_ms: int
    target: CaptureTarget
    ok: Literal[False] = False


CaptureResult = Union[CaptureSuccess[T], CaptureErrorResult]


@dataclass(frozen=True)
class PortraitistOptions:
    """Reusable capture defaults for a :class:`Portraitist`.

    ``env`` augments (never replaces) the parent process environment.
    """

    cwd: str | None = None
    env: Mapping[str, str] | None = None
    fail_on_nonzero_exit: bool = True
    logger: CaptureLogger | None = None
    parse_input: CaptureParseInput | None = None
    shell: bool | None = None
    stderr: CaptureStderrPolicy = "capture"
    stdin: str | bytes | None = None
    timeout_ms: int | None = None
    interpreters: Mapping[str, CaptureInterpreterInput] | None = None


# Grace period between SIGTERM and SIGKILL on timeout.
_KILL_GRACE_S: Final = 0.1
# Bound on joining worker threads that may be held open by escaped
# descendants; after this they are abandoned (they are daemon threads).
_ABANDON_JOIN_S: Final = 1.0
_READ_CHUNK_SIZE: Final = 65536


class Portraitist:
    """Main configurable actor owning reusable capture defaults.

    Per-call options default to :data:`UNSET`; any explicitly supplied
    value (including ``None``) overrides — and can clear — the
    corresponding constructor default. Keyword arguments to the
    constructor likewise override fields of a supplied
    :class:`PortraitistOptions`.
    """

    def __init__(
        self,
        options: PortraitistOptions | None = None,
        *,
        cwd: str | None | _UnsetType = UNSET,
        env: Mapping[str, str] | None | _UnsetType = UNSET,
        fail_on_nonzero_exit: bool | _UnsetType = UNSET,
        logger: CaptureLogger | None | _UnsetType = UNSET,
        parse_input: CaptureParseInput | None | _UnsetType = UNSET,
        shell: bool | None | _UnsetType = UNSET,
        stderr: CaptureStderrPolicy | _UnsetType = UNSET,
        stdin: str | bytes | None | _UnsetType = UNSET,
        timeout_ms: int | None | _UnsetType = UNSET,
        interpreters: Mapping[str, CaptureInterpreterInput] | None | _UnsetType = UNSET,
    ) -> None:
        base = options if options is not None else PortraitistOptions()
        self._defaults = PortraitistOptions(
            cwd=_pick(cwd, base.cwd),
            env=_pick(env, base.env),
            fail_on_nonzero_exit=_pick(fail_on_nonzero_exit, base.fail_on_nonzero_exit),
            logger=_pick(logger, base.logger),
            parse_input=_pick(parse_input, base.parse_input),
            shell=_pick(shell, base.shell),
            stderr=_pick(stderr, base.stderr),
            stdin=_pick(stdin, base.stdin),
            timeout_ms=_pick(timeout_ms, base.timeout_ms),
            interpreters=_pick(interpreters, base.interpreters),
        )
        self._interpreters = _normalize_interpreters(self._defaults.interpreters)

    @overload
    def capture_command(
        self,
        command: str,
        *,
        parser: CaptureParser[T],
        cwd: str | None | _UnsetType = UNSET,
        env: Mapping[str, str] | None | _UnsetType = UNSET,
        fail_on_nonzero_exit: bool | _UnsetType = UNSET,
        logger: CaptureLogger | None | _UnsetType = UNSET,
        parse_input: CaptureParseInput | None | _UnsetType = UNSET,
        shell: bool | None | _UnsetType = UNSET,
        stderr: CaptureStderrPolicy | _UnsetType = UNSET,
        stdin: str | bytes | None | _UnsetType = UNSET,
        timeout_ms: int | None | _UnsetType = UNSET,
    ) -> CaptureResult[T]: ...

    @overload
    def capture_command(
        self,
        command: str,
        *,
        parser: None = None,
        cwd: str | None | _UnsetType = UNSET,
        env: Mapping[str, str] | None | _UnsetType = UNSET,
        fail_on_nonzero_exit: bool | _UnsetType = UNSET,
        logger: CaptureLogger | None | _UnsetType = UNSET,
        parse_input: CaptureParseInput | None | _UnsetType = UNSET,
        shell: bool | None | _UnsetType = UNSET,
        stderr: CaptureStderrPolicy | _UnsetType = UNSET,
        stdin: str | bytes | None | _UnsetType = UNSET,
        timeout_ms: int | None | _UnsetType = UNSET,
    ) -> CaptureResult[str]: ...

    def capture_command(
        self,
        command: str,
        *,
        parser: CaptureParser[Any] | None = None,
        cwd: str | None | _UnsetType = UNSET,
        env: Mapping[str, str] | None | _UnsetType = UNSET,
        fail_on_nonzero_exit: bool | _UnsetType = UNSET,
        logger: CaptureLogger | None | _UnsetType = UNSET,
        parse_input: CaptureParseInput | None | _UnsetType = UNSET,
        shell: bool | None | _UnsetType = UNSET,
        stderr: CaptureStderrPolicy | _UnsetType = UNSET,
        stdin: str | bytes | None | _UnsetType = UNSET,
        timeout_ms: int | None | _UnsetType = UNSET,
    ) -> CaptureResult[Any]:
        """Run a shell command string (platform shell by default).

        With ``shell=False`` the string is split into an argv with POSIX
        ``shlex`` rules on every platform, so quoting is honored but no
        shell expansion or operators apply.
        """
        target = CaptureTarget(kind="command", command=command, args=())
        return self._run(
            target,
            "command",
            parser=parser,
            cwd=cwd,
            env=env,
            fail_on_nonzero_exit=fail_on_nonzero_exit,
            logger=logger,
            parse_input=parse_input,
            shell=shell,
            stderr=stderr,
            stdin=stdin,
            timeout_ms=timeout_ms,
        )

    @overload
    def capture_process(
        self,
        program: str,
        args: Sequence[str] | None = None,
        *,
        parser: CaptureParser[T],
        cwd: str | None | _UnsetType = UNSET,
        env: Mapping[str, str] | None | _UnsetType = UNSET,
        fail_on_nonzero_exit: bool | _UnsetType = UNSET,
        logger: CaptureLogger | None | _UnsetType = UNSET,
        parse_input: CaptureParseInput | None | _UnsetType = UNSET,
        shell: bool | None | _UnsetType = UNSET,
        stderr: CaptureStderrPolicy | _UnsetType = UNSET,
        stdin: str | bytes | None | _UnsetType = UNSET,
        timeout_ms: int | None | _UnsetType = UNSET,
    ) -> CaptureResult[T]: ...

    @overload
    def capture_process(
        self,
        program: str,
        args: Sequence[str] | None = None,
        *,
        parser: None = None,
        cwd: str | None | _UnsetType = UNSET,
        env: Mapping[str, str] | None | _UnsetType = UNSET,
        fail_on_nonzero_exit: bool | _UnsetType = UNSET,
        logger: CaptureLogger | None | _UnsetType = UNSET,
        parse_input: CaptureParseInput | None | _UnsetType = UNSET,
        shell: bool | None | _UnsetType = UNSET,
        stderr: CaptureStderrPolicy | _UnsetType = UNSET,
        stdin: str | bytes | None | _UnsetType = UNSET,
        timeout_ms: int | None | _UnsetType = UNSET,
    ) -> CaptureResult[str]: ...

    def capture_process(
        self,
        program: str,
        args: Sequence[str] | None = None,
        *,
        parser: CaptureParser[Any] | None = None,
        cwd: str | None | _UnsetType = UNSET,
        env: Mapping[str, str] | None | _UnsetType = UNSET,
        fail_on_nonzero_exit: bool | _UnsetType = UNSET,
        logger: CaptureLogger | None | _UnsetType = UNSET,
        parse_input: CaptureParseInput | None | _UnsetType = UNSET,
        shell: bool | None | _UnsetType = UNSET,
        stderr: CaptureStderrPolicy | _UnsetType = UNSET,
        stdin: str | bytes | None | _UnsetType = UNSET,
        timeout_ms: int | None | _UnsetType = UNSET,
    ) -> CaptureResult[Any]:
        """Run an executable plus literal arguments (no shell by default).

        With ``shell=True`` the program and every argument are shell-quoted
        (``shlex.join`` on POSIX) before being handed to the shell, so
        arguments are never subject to injection or word splitting.
        """
        target = CaptureTarget(kind="process", command=program, args=tuple(args or ()))
        return self._run(
            target,
            "process",
            parser=parser,
            cwd=cwd,
            env=env,
            fail_on_nonzero_exit=fail_on_nonzero_exit,
            logger=logger,
            parse_input=parse_input,
            shell=shell,
            stderr=stderr,
            stdin=stdin,
            timeout_ms=timeout_ms,
        )

    @overload
    def capture_script(
        self,
        path: str,
        args: Sequence[str] | None = None,
        *,
        parser: CaptureParser[T],
        interpreter: CaptureInterpreterInput | None | _UnsetType = UNSET,
        cwd: str | None | _UnsetType = UNSET,
        env: Mapping[str, str] | None | _UnsetType = UNSET,
        fail_on_nonzero_exit: bool | _UnsetType = UNSET,
        logger: CaptureLogger | None | _UnsetType = UNSET,
        parse_input: CaptureParseInput | None | _UnsetType = UNSET,
        shell: bool | None | _UnsetType = UNSET,
        stderr: CaptureStderrPolicy | _UnsetType = UNSET,
        stdin: str | bytes | None | _UnsetType = UNSET,
        timeout_ms: int | None | _UnsetType = UNSET,
    ) -> CaptureResult[T]: ...

    @overload
    def capture_script(
        self,
        path: str,
        args: Sequence[str] | None = None,
        *,
        parser: None = None,
        interpreter: CaptureInterpreterInput | None | _UnsetType = UNSET,
        cwd: str | None | _UnsetType = UNSET,
        env: Mapping[str, str] | None | _UnsetType = UNSET,
        fail_on_nonzero_exit: bool | _UnsetType = UNSET,
        logger: CaptureLogger | None | _UnsetType = UNSET,
        parse_input: CaptureParseInput | None | _UnsetType = UNSET,
        shell: bool | None | _UnsetType = UNSET,
        stderr: CaptureStderrPolicy | _UnsetType = UNSET,
        stdin: str | bytes | None | _UnsetType = UNSET,
        timeout_ms: int | None | _UnsetType = UNSET,
    ) -> CaptureResult[str]: ...

    def capture_script(
        self,
        path: str,
        args: Sequence[str] | None = None,
        *,
        parser: CaptureParser[Any] | None = None,
        interpreter: CaptureInterpreterInput | None | _UnsetType = UNSET,
        cwd: str | None | _UnsetType = UNSET,
        env: Mapping[str, str] | None | _UnsetType = UNSET,
        fail_on_nonzero_exit: bool | _UnsetType = UNSET,
        logger: CaptureLogger | None | _UnsetType = UNSET,
        parse_input: CaptureParseInput | None | _UnsetType = UNSET,
        shell: bool | None | _UnsetType = UNSET,
        stderr: CaptureStderrPolicy | _UnsetType = UNSET,
        stdin: str | bytes | None | _UnsetType = UNSET,
        timeout_ms: int | None | _UnsetType = UNSET,
    ) -> CaptureResult[Any]:
        """Run a script file path with optional arguments.

        ``interpreter`` left at :data:`UNSET` uses the constructor default
        interpreter for the script's extension (if any); ``interpreter=None``
        explicitly runs the path directly, clearing any extension default.
        """
        script_args = tuple(args or ())
        resolved = _resolve_script_interpreter(path, self._interpreters, interpreter)
        target = _script_target(path, script_args, resolved)
        return self._run(
            target,
            "script",
            parser=parser,
            cwd=cwd,
            env=env,
            fail_on_nonzero_exit=fail_on_nonzero_exit,
            logger=logger,
            parse_input=parse_input,
            shell=shell,
            stderr=stderr,
            stdin=stdin,
            timeout_ms=timeout_ms,
        )

    def _run(
        self,
        target: CaptureTarget,
        kind: CaptureTargetKind,
        *,
        parser: CaptureParser[Any] | None,
        cwd: str | None | _UnsetType,
        env: Mapping[str, str] | None | _UnsetType,
        fail_on_nonzero_exit: bool | _UnsetType,
        logger: CaptureLogger | None | _UnsetType,
        parse_input: CaptureParseInput | None | _UnsetType,
        shell: bool | None | _UnsetType,
        stderr: CaptureStderrPolicy | _UnsetType,
        stdin: str | bytes | None | _UnsetType,
        timeout_ms: int | None | _UnsetType,
    ) -> CaptureResult[Any]:
        defaults = self._defaults
        return run_capture(
            target,
            cwd=_pick(cwd, defaults.cwd),
            env=self._merged_env(env),
            fail_on_nonzero_exit=_pick(fail_on_nonzero_exit, defaults.fail_on_nonzero_exit),
            logger=_pick(logger, defaults.logger),
            parse_input=_pick(parse_input, defaults.parse_input),
            parser=parser,
            shell=self._resolved_shell(kind, shell),
            stderr=_pick(stderr, defaults.stderr),
            stdin=_pick(stdin, defaults.stdin),
            timeout_ms=_pick(timeout_ms, defaults.timeout_ms),
        )

    def _merged_env(
        self, env: Mapping[str, str] | None | _UnsetType
    ) -> Mapping[str, str] | None:
        """Overlay the per-call env on the constructor default env.

        The result is later overlaid on ``os.environ`` by ``run_capture``.
        ``env=None`` per call clears the constructor default entirely.
        """
        if isinstance(env, _UnsetType):
            return self._defaults.env
        if env is None or self._defaults.env is None:
            return env
        return {**self._defaults.env, **env}

    def _resolved_shell(
        self, kind: CaptureTargetKind, shell: bool | None | _UnsetType
    ) -> bool:
        if isinstance(shell, bool):
            return shell
        if isinstance(shell, _UnsetType) and self._defaults.shell is not None:
            return self._defaults.shell
        # shell=None per call clears a constructor default back to the
        # kind-based default: shell for commands, no shell otherwise.
        return kind == "command"


class CaptureNamespace:
    """Convenience facade bound to a :class:`Portraitist` instance.

    Exposes ``command``, ``process``, and ``script`` as direct aliases of
    the portraitist's capture methods, enabling
    ``from portraiture import capture; capture.command(...)``.
    """

    __slots__ = ("command", "process", "script")

    def __init__(self, portraitist: Portraitist) -> None:
        self.command = portraitist.capture_command
        self.process = portraitist.capture_process
        self.script = portraitist.capture_script


@overload
def run_capture(
    target: CaptureTarget,
    *,
    parser: CaptureParser[T],
    cwd: str | None = None,
    env: Mapping[str, str] | None = None,
    fail_on_nonzero_exit: bool = True,
    logger: CaptureLogger | None = None,
    parse_input: CaptureParseInput | None = None,
    shell: bool = False,
    stderr: CaptureStderrPolicy = "capture",
    stdin: str | bytes | None = None,
    timeout_ms: int | None = None,
    encoding: str = "utf-8",
    errors: str = "replace",
) -> CaptureResult[T]: ...


@overload
def run_capture(
    target: CaptureTarget,
    *,
    parser: None = None,
    cwd: str | None = None,
    env: Mapping[str, str] | None = None,
    fail_on_nonzero_exit: bool = True,
    logger: CaptureLogger | None = None,
    parse_input: CaptureParseInput | None = None,
    shell: bool = False,
    stderr: CaptureStderrPolicy = "capture",
    stdin: str | bytes | None = None,
    timeout_ms: int | None = None,
    encoding: str = "utf-8",
    errors: str = "replace",
) -> CaptureResult[str]: ...


def run_capture(
    target: CaptureTarget,
    *,
    parser: CaptureParser[Any] | None = None,
    cwd: str | None = None,
    env: Mapping[str, str] | None = None,
    fail_on_nonzero_exit: bool = True,
    logger: CaptureLogger | None = None,
    parse_input: CaptureParseInput | None = None,
    shell: bool = False,
    stderr: CaptureStderrPolicy = "capture",
    stdin: str | bytes | None = None,
    timeout_ms: int | None = None,
    encoding: str = "utf-8",
    errors: str = "replace",
) -> CaptureResult[Any]:
    """Launch a capture target and return a structured result.

    ``env`` augments the parent environment (``os.environ`` overlaid with
    ``env``); ``env=None`` inherits the parent environment unchanged.

    Without a ``parser``, ``value`` is the combined output string; stdout
    and stderr are interleaved in best-effort arrival order, which is not
    guaranteed to be stable across runs (see module docstring).

    ``timeout_ms`` bounds the whole call, including stdin delivery. On
    POSIX the child runs in its own process group, which is terminated as
    a whole on timeout.

    ``logger`` may be invoked concurrently from reader threads and must
    be thread-safe. Exactly one terminal ``finish`` event is emitted per
    capture, including for spawn failures.
    """
    started_at = time.monotonic()
    chunks: list[CaptureChunk] = []
    lock = threading.Lock()

    _emit(logger, {"type": "start", "target": target})

    try:
        popen_args = _popen_args(target, shell)
        process = subprocess.Popen(
            popen_args,
            cwd=cwd,
            env=_effective_env(env),
            shell=shell,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=(os.name == "posix"),
        )
    except Exception as cause:
        duration_ms = round((time.monotonic() - started_at) * 1000)
        _emit(
            logger,
            {
                "type": "finish",
                "ok": False,
                "duration_ms": duration_ms,
                "exit_code": None,
                "signal": None,
            },
        )
        return CaptureErrorResult(
            error=CaptureFailure(
                kind="spawn",
                message=str(cause) or "Failed to start capture target.",
                cause=cause,
            ),
            stdout="",
            stderr="",
            output="",
            chunks=(),
            exit_code=None,
            signal=None,
            duration_ms=duration_ms,
            target=target,
        )

    stdout_thread = threading.Thread(
        target=_read_pipe,
        args=("stdout", process.stdout, chunks, lock, logger, encoding, errors),
        daemon=True,
    )
    stderr_thread = threading.Thread(
        target=_read_pipe,
        args=("stderr", process.stderr, chunks, lock, logger, encoding, errors),
        daemon=True,
    )
    stdin_thread = threading.Thread(
        target=_write_stdin,
        args=(process.stdin, None if stdin is None else _encode_stdin(stdin, encoding)),
        daemon=True,
    )

    stdout_thread.start()
    stderr_thread.start()
    stdin_thread.start()

    timed_out = False
    try:
        process.wait(timeout=_remaining_seconds(started_at, timeout_ms))
    except subprocess.TimeoutExpired:
        timed_out = True
        _kill_process_tree(process)

    # After the child has exited (or its group was killed), the workers
    # normally finish promptly. On timeout, an escaped descendant may keep
    # a pipe open; bound the joins and abandon the daemon threads instead
    # of hanging. Stdin joins are always bounded: a grandchild inheriting
    # the stdin pipe could otherwise block the writer indefinitely.
    stdin_thread.join(timeout=_ABANDON_JOIN_S)
    reader_join_timeout = _ABANDON_JOIN_S if timed_out else None
    stdout_thread.join(timeout=reader_join_timeout)
    stderr_thread.join(timeout=reader_join_timeout)

    duration_ms = round((time.monotonic() - started_at) * 1000)
    with lock:
        frozen_chunks = tuple(chunks)
    stdout = "".join(chunk.text for chunk in frozen_chunks if chunk.stream == "stdout")
    stderr_text = "".join(chunk.text for chunk in frozen_chunks if chunk.stream == "stderr")
    output = "".join(chunk.text for chunk in frozen_chunks)
    exit_code, signal_number = _return_code_parts(process.returncode)

    context = CaptureContext(
        stdout=stdout,
        stderr=stderr_text,
        output=output,
        chunks=frozen_chunks,
        exit_code=exit_code,
        signal=signal_number,
        duration_ms=duration_ms,
    )

    if timed_out:
        return _finish_failure(
            logger,
            target,
            context,
            CaptureFailure("timeout", f"Capture target timed out after {timeout_ms}ms."),
        )

    if fail_on_nonzero_exit and process.returncode != 0:
        exit_message = (
            f"Capture target exited with code {exit_code}."
            if exit_code is not None
            else f"Capture target exited with signal {signal_number}."
        )
        return _finish_failure(
            logger,
            target,
            context,
            CaptureFailure("exit", exit_message),
        )

    if stderr == "fail" and stderr_text:
        return _finish_failure(
            logger,
            target,
            context,
            CaptureFailure("stderr", "Capture target wrote to stderr."),
        )

    try:
        selected_text = _select_text(context, parse_input or ("stdout" if parser else "combined"))
        value = parser(selected_text) if parser is not None else selected_text
    except Exception as cause:
        return _finish_failure(
            logger,
            target,
            context,
            CaptureFailure("parse", str(cause) or "Parser failed.", cause),
        )

    _emit(
        logger,
        {
            "type": "finish",
            "ok": True,
            "duration_ms": duration_ms,
            "exit_code": exit_code,
            "signal": signal_number,
        },
    )

    return CaptureSuccess(
        value=value,
        stdout=stdout,
        stderr=stderr_text,
        output=output,
        chunks=frozen_chunks,
        exit_code=exit_code,
        signal=signal_number,
        duration_ms=duration_ms,
        target=target,
    )


def _pick(value: T | _UnsetType, default: T) -> T:
    return default if isinstance(value, _UnsetType) else value


def _effective_env(env: Mapping[str, str] | None) -> dict[str, str] | None:
    """Overlay supplied variables on the parent environment (augment)."""
    if env is None:
        return None
    return {**os.environ, **env}


def _popen_args(target: CaptureTarget, shell: bool) -> str | list[str]:
    """Build the Popen argument for a target.

    - ``shell=True``, command target: the command string is passed to the
      shell verbatim (shell semantics are the point of ``capture_command``).
    - ``shell=True`` with arguments (process/script targets): each element
      is shell-quoted — ``shlex.join`` on POSIX,
      ``subprocess.list2cmdline`` elsewhere — so literal arguments can
      never be interpreted as shell syntax.
    - ``shell=False``, command target: the string is split with POSIX
      ``shlex`` rules (on all platforms) into an argv.
    - otherwise: the literal argv is used.
    """
    argv = [target.command, *target.args]
    if shell:
        if len(argv) == 1:
            return target.command
        if os.name == "posix":
            return shlex.join(argv)
        return subprocess.list2cmdline(argv)

    if target.kind == "command" and not target.args:
        parts = shlex.split(target.command)
        if not parts:
            raise ValueError("Command string is empty.")
        return parts

    return argv


def _remaining_seconds(started_at: float, timeout_ms: int | None) -> float | None:
    if timeout_ms is None:
        return None
    return max(0.0, timeout_ms / 1000 - (time.monotonic() - started_at))


def _kill_process_tree(process: subprocess.Popen[bytes]) -> None:
    """Terminate the child and, on POSIX, its whole process group.

    Sends SIGTERM to the group first, escalating to SIGKILL after a short
    grace period. Descendants that started their own session are not in
    the group and cannot be reached (documented limitation).
    """
    if os.name == "posix":
        _signal_group(process, signal.SIGTERM)
        try:
            process.wait(timeout=_KILL_GRACE_S)
        except subprocess.TimeoutExpired:
            _signal_group(process, signal.SIGKILL)
    else:
        try:
            process.kill()
        except OSError:
            pass
    process.wait()


def _signal_group(process: subprocess.Popen[bytes], signal_number: int) -> None:
    try:
        # start_new_session=True makes the child a session/group leader,
        # so its pid is its process group id.
        os.killpg(process.pid, signal_number)
    except (ProcessLookupError, PermissionError, OSError):
        try:
            process.send_signal(signal_number)
        except (ProcessLookupError, OSError):
            pass


def _script_target(
    path: str,
    args: tuple[str, ...],
    interpreter: CaptureInterpreter | None,
) -> CaptureTarget:
    if interpreter is None:
        return CaptureTarget(kind="script", command=path, args=args, script=path)

    return CaptureTarget(
        kind="script",
        command=interpreter.command,
        args=(*interpreter.args, path, *args),
        script=path,
        interpreter=interpreter,
    )


def _resolve_script_interpreter(
    path: str,
    interpreters: Mapping[str, CaptureInterpreter],
    explicit: CaptureInterpreterInput | None | _UnsetType,
) -> CaptureInterpreter | None:
    if explicit is None:
        # Explicitly cleared: run the path directly even if a default
        # interpreter is configured for its extension.
        return None

    if not isinstance(explicit, _UnsetType):
        return _normalize_interpreter(explicit)

    extension = _normalize_extension(os.path.splitext(path)[1])
    if extension is None:
        return None

    return interpreters.get(extension)


def _normalize_interpreters(
    interpreters: Mapping[str, CaptureInterpreterInput] | None,
) -> dict[str, CaptureInterpreter]:
    return {
        _normalize_extension(extension) or extension: _normalize_interpreter(interpreter)
        for extension, interpreter in (interpreters or {}).items()
    }


def _normalize_interpreter(interpreter: CaptureInterpreterInput) -> CaptureInterpreter:
    if isinstance(interpreter, CaptureInterpreter):
        return interpreter

    if isinstance(interpreter, str):
        return CaptureInterpreter(command=interpreter, args=())

    if len(interpreter) == 0:
        raise ValueError("Interpreter sequence must include a command.")

    return CaptureInterpreter(command=interpreter[0], args=tuple(interpreter[1:]))


def _normalize_extension(extension: str) -> str | None:
    if not extension:
        return None

    normalized = extension.lower()
    return normalized if normalized.startswith(".") else f".{normalized}"


def _read_pipe(
    stream: CaptureStream,
    pipe: Any,
    chunks: list[CaptureChunk],
    lock: threading.Lock,
    logger: CaptureLogger | None,
    encoding: str,
    errors: str,
) -> None:
    if pipe is None:
        return

    try:
        while True:
            # read1 returns as soon as any data is available, so chunks
            # and logger events stream as the child produces output.
            data = pipe.read1(_READ_CHUNK_SIZE)
            if not data:
                break

            text = data.decode(encoding, errors=errors)
            with lock:
                chunks.append(CaptureChunk(stream=stream, text=text))

            _emit(logger, {"type": stream, "text": text})
    except (OSError, ValueError):
        pass
    finally:
        try:
            pipe.close()
        except OSError:
            pass


def _write_stdin(pipe: Any, data: bytes | None) -> None:
    """Deliver stdin from a worker thread so the caller can never deadlock.

    Broken pipes (child exited or never read stdin) are swallowed; they
    surface, if at all, through the child's own exit status.
    """
    if pipe is None:
        return

    try:
        if data:
            pipe.write(data)
    except (BrokenPipeError, OSError):
        pass
    finally:
        try:
            pipe.close()
        except (BrokenPipeError, OSError):
            pass


def _encode_stdin(stdin: str | bytes, encoding: str) -> bytes:
    return stdin.encode(encoding) if isinstance(stdin, str) else stdin


def _return_code_parts(return_code: int | None) -> tuple[int | None, int | None]:
    if return_code is None:
        return None, None

    if return_code < 0:
        return None, -return_code

    return return_code, None


def _select_text(context: CaptureContext, parse_input: CaptureParseInput) -> str:
    if parse_input == "stdout":
        return context.stdout

    if parse_input == "stderr":
        return context.stderr

    return context.output


def _finish_failure(
    logger: CaptureLogger | None,
    target: CaptureTarget,
    context: CaptureContext,
    error: CaptureFailure,
) -> CaptureErrorResult:
    _emit(
        logger,
        {
            "type": "finish",
            "ok": False,
            "duration_ms": context.duration_ms,
            "exit_code": context.exit_code,
            "signal": context.signal,
        },
    )

    return CaptureErrorResult(
        error=error,
        stdout=context.stdout,
        stderr=context.stderr,
        output=context.output,
        chunks=context.chunks,
        exit_code=context.exit_code,
        signal=context.signal,
        duration_ms=context.duration_ms,
        target=target,
    )


def _emit(logger: CaptureLogger | None, event: CaptureLogEvent) -> None:
    if logger is None:
        return

    try:
        logger(event)
    except Exception:
        pass


portraitist: Final = Portraitist()
"""Default :class:`Portraitist` instance with built-in defaults."""

capture: Final = CaptureNamespace(portraitist)
"""Convenience namespace bound to the default portraitist:
``capture.command(...)``, ``capture.process(...)``, ``capture.script(...)``.
"""
