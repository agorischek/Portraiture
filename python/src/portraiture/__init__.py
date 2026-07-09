"""Portraiture: run external commands, processes, and scripts and capture
a structured portrait of their output.

Public API surface; the implementation lives in :mod:`portraiture._core`.
See that module's docstring (and the package README) for the environment
augmentation, combined-``value``, timeout, and logger thread-safety
semantics shared by all Portraiture ports.
"""

from portraiture._core import (
    UNSET,
    CaptureChunk,
    CaptureContext,
    CaptureErrorResult,
    CaptureFailure,
    CaptureFailureKind,
    CaptureFinishEvent,
    CaptureInterpreter,
    CaptureInterpreterInput,
    CaptureLogEvent,
    CaptureLogger,
    CaptureNamespace,
    CaptureParseInput,
    CaptureParser,
    CaptureResult,
    CaptureStartEvent,
    CaptureStderrEvent,
    CaptureStderrPolicy,
    CaptureStdoutEvent,
    CaptureStream,
    CaptureSuccess,
    CaptureTarget,
    CaptureTargetKind,
    Portraitist,
    PortraitistOptions,
    capture,
    portraitist,
    run_capture,
)

__all__ = [
    "CaptureChunk",
    "CaptureContext",
    "CaptureErrorResult",
    "CaptureFailure",
    "CaptureFailureKind",
    "CaptureFinishEvent",
    "CaptureInterpreter",
    "CaptureInterpreterInput",
    "CaptureLogEvent",
    "CaptureLogger",
    "CaptureNamespace",
    "CaptureParseInput",
    "CaptureParser",
    "CaptureResult",
    "CaptureStartEvent",
    "CaptureStderrEvent",
    "CaptureStderrPolicy",
    "CaptureStdoutEvent",
    "CaptureStream",
    "CaptureSuccess",
    "CaptureTarget",
    "CaptureTargetKind",
    "Portraitist",
    "PortraitistOptions",
    "UNSET",
    "capture",
    "portraitist",
    "run_capture",
]
