using System.Text;
using Microsoft.Extensions.Logging;

namespace Portraiture;

/// <summary>
/// Per-call capture options. Any property left <see langword="null"/> falls back to the owning
/// <see cref="Portraitist"/>'s constructor defaults, then to the built-in defaults.
/// </summary>
public class CaptureOptions
{
    /// <summary>
    /// Working directory for the child process. Affects process launch only; the host application's
    /// current directory is never changed. Defaults to the host process working directory.
    /// </summary>
    public string? WorkingDirectory { get; init; }

    /// <summary>
    /// Environment variables for the child process. Supplied variables <b>augment</b> the parent
    /// process environment rather than replacing it: the child inherits the full host environment
    /// and each entry here is layered on top. An entry whose value is <see langword="null"/>
    /// <b>removes</b> that variable from the child environment. When set per call, this dictionary
    /// replaces the constructor-default dictionary wholesale (the two are not merged); the winning
    /// dictionary is then layered onto the parent environment.
    /// </summary>
    public IReadOnlyDictionary<string, string?>? Environment { get; init; }

    /// <summary>
    /// Whether a nonzero exit code fails the capture with kind <see cref="CaptureFailureKind.Exit"/>.
    /// Defaults to <see langword="true"/>. Set to <see langword="false"/> to collect nonzero exits as
    /// successful data; captured output remains available either way.
    /// </summary>
    public bool? FailOnNonZeroExit { get; init; }

    /// <summary>
    /// Logger for lifecycle and stream events. <c>Started</c> and <c>Succeeded</c> are logged at
    /// Information, output chunks at Trace, and failures at Warning. Logger exceptions are swallowed
    /// and never change the capture result.
    /// </summary>
    public ILogger? Logger { get; init; }

    /// <summary>
    /// Which captured text is passed to the parser. Defaults to <see cref="CaptureParseInput.Stdout"/>
    /// when a parser is provided and <see cref="CaptureParseInput.Combined"/> otherwise.
    /// </summary>
    public CaptureParseInput? ParseInput { get; init; }

    /// <summary>Explicit interpreter for script captures. Ignored by command and process captures.</summary>
    public CaptureInterpreter? Interpreter { get; init; }

    /// <summary>
    /// Whether to launch the target through the platform shell (<c>/bin/sh -c</c> on POSIX,
    /// <c>cmd.exe /c</c> on Windows). Defaults to <see langword="true"/> for command captures and
    /// <see langword="false"/> for process and script captures. When enabled for a process or script
    /// target on POSIX, the program and its arguments are single-quoted into the shell command line so
    /// they are passed literally. On Windows, enabling the shell for a target that has arguments throws
    /// <see cref="NotSupportedException"/>, because <c>cmd.exe</c> has no reliable argument quoting.
    /// </summary>
    public bool? UseShell { get; init; }

    /// <summary>
    /// Stderr policy. The default, <see cref="CaptureStderrPolicy.Capture"/>, records stderr as data.
    /// <see cref="CaptureStderrPolicy.Fail"/> turns any non-empty stderr into a failed result with kind
    /// <see cref="CaptureFailureKind.Stderr"/>; the stderr text stays available on that result.
    /// </summary>
    public CaptureStderrPolicy? Stderr { get; init; }

    /// <summary>
    /// Text written to the child's standard input before it is closed. Writing happens concurrently
    /// with the run, so <see cref="Timeout"/> also bounds a child that never reads its stdin. If the
    /// child exits without draining stdin, the resulting broken-pipe error is ignored.
    /// </summary>
    public string? StandardInput { get; init; }

    /// <summary>
    /// Encoding used to decode the child's stdout and stderr. Defaults to UTF-8. Decoding is stateful
    /// per stream, so multibyte characters split across internal read buffers are decoded correctly.
    /// </summary>
    public Encoding? Encoding { get; init; }

    /// <summary>
    /// Maximum run time. On expiry the entire child process tree is killed and the capture returns a
    /// failed result with kind <see cref="CaptureFailureKind.Timeout"/>; output captured before the
    /// timeout remains available. This is distinct from cancelling via <see cref="CancellationToken"/>,
    /// which kills the process tree and then <b>throws</b> <see cref="OperationCanceledException"/>
    /// instead of returning a result. When both occur, cancellation wins.
    /// </summary>
    public TimeSpan? Timeout { get; init; }
}
