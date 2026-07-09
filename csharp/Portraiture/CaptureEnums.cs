namespace Portraiture;

/// <summary>Identifies which capture entry point produced a <see cref="CaptureTarget"/>.</summary>
public enum CaptureTargetKind
{
    /// <summary>A shell command string, normally run through the platform shell.</summary>
    Command,

    /// <summary>An executable plus literal arguments, run without shell interpretation by default.</summary>
    Process,

    /// <summary>A script file path, optionally launched through a configured interpreter.</summary>
    Script,
}

/// <summary>Identifies which output stream a <see cref="CaptureChunk"/> came from.</summary>
public enum CaptureStream
{
    /// <summary>The child process standard output stream.</summary>
    Stdout,

    /// <summary>The child process standard error stream.</summary>
    Stderr,
}

/// <summary>Selects which captured text is handed to a parser.</summary>
public enum CaptureParseInput
{
    /// <summary>Stdout and stderr chunks concatenated in arrival order.</summary>
    Combined,

    /// <summary>Captured standard output only. This is the default when a parser is provided.</summary>
    Stdout,

    /// <summary>Captured standard error only.</summary>
    Stderr,
}

/// <summary>Controls how captured stderr affects the result.</summary>
public enum CaptureStderrPolicy
{
    /// <summary>Capture stderr as data without failing the result. This is the default.</summary>
    Capture,

    /// <summary>
    /// Treat any non-empty stderr as a failure with kind <see cref="CaptureFailureKind.Stderr"/>.
    /// The stderr text remains available on the failed result.
    /// </summary>
    Fail,
}

/// <summary>Classifies why a capture failed.</summary>
public enum CaptureFailureKind
{
    /// <summary>The process exited with a nonzero exit code while <see cref="CaptureOptions.FailOnNonZeroExit"/> was in effect.</summary>
    Exit,

    /// <summary>The parser threw an exception. The captured output remains available on the result.</summary>
    Parse,

    /// <summary>The process could not be started.</summary>
    Spawn,

    /// <summary>The process wrote to stderr while <see cref="CaptureStderrPolicy.Fail"/> was in effect.</summary>
    Stderr,

    /// <summary>
    /// The process exceeded <see cref="CaptureOptions.Timeout"/>. The entire child process tree is killed
    /// and output captured before the timeout remains available on the failed result.
    /// </summary>
    Timeout,
}
