namespace Portraiture;

/// <summary>
/// The outcome of a capture: either a successful <see cref="Value"/> or a structured
/// <see cref="Error"/>, plus everything that was captured along the way.
/// </summary>
/// <typeparam name="T">The parsed value type. Captures without a parser produce <c>CaptureResult&lt;string&gt;</c>.</typeparam>
public sealed class CaptureResult<T>
{
    private readonly T? value;
    private readonly CaptureFailure? error;

    private CaptureResult(
        bool ok,
        T? value,
        CaptureFailure? error,
        string stdout,
        string stderr,
        string output,
        IReadOnlyList<CaptureChunk> chunks,
        int? exitCode,
        int? signal,
        TimeSpan duration,
        CaptureTarget target)
    {
        Ok = ok;
        this.value = value;
        this.error = error;
        Stdout = stdout;
        Stderr = stderr;
        Output = output;
        Chunks = chunks;
        ExitCode = exitCode;
        Signal = signal;
        Duration = duration;
        Target = target;
    }

    /// <summary>Whether the capture succeeded.</summary>
    public bool Ok { get; }

    /// <summary>
    /// The parsed value. Without a parser this is the combined output string.
    /// </summary>
    /// <exception cref="InvalidOperationException">The capture failed; check <see cref="Ok"/> first.</exception>
    public T Value => Ok
        ? value!
        : throw new InvalidOperationException("Cannot read Value from a failed capture result.");

    /// <summary>The structured failure.</summary>
    /// <exception cref="InvalidOperationException">The capture succeeded; check <see cref="Ok"/> first.</exception>
    public CaptureFailure Error => !Ok
        ? error!
        : throw new InvalidOperationException("Cannot read Error from a successful capture result.");

    /// <summary>All captured standard output. Available on failed results too.</summary>
    public string Stdout { get; }

    /// <summary>All captured standard error. Available on failed results too.</summary>
    public string Stderr { get; }

    /// <summary>Stdout and stderr chunks concatenated in arrival order.</summary>
    public string Output { get; }

    /// <summary>The individual output chunks in arrival order.</summary>
    public IReadOnlyList<CaptureChunk> Chunks { get; }

    /// <summary>The process exit code, or <see langword="null"/> if the process never started or never exited.</summary>
    public int? ExitCode { get; }

    /// <summary>
    /// Best-effort Unix signal number that terminated the process, or <see langword="null"/> when the
    /// process exited normally or the signal cannot be determined.
    /// </summary>
    /// <remarks>
    /// On Unix this is inferred two ways: when Portraiture itself kills the process tree on timeout,
    /// the signal is reported as 9 (SIGKILL); otherwise a signal death is inferred from the .NET
    /// convention of reporting exit code <c>128 + n</c> for a process killed by signal <c>n</c>. The
    /// heuristic cannot distinguish a real signal death from a process that deliberately exits with a
    /// code in the 129–192 range (for example <c>exit 137</c>), so such exits are reported as signals.
    /// On Windows this is always <see langword="null"/>.
    /// </remarks>
    public int? Signal { get; }

    /// <summary>Wall-clock duration of the capture.</summary>
    public TimeSpan Duration { get; }

    /// <summary>The resolved target that was launched.</summary>
    public CaptureTarget Target { get; }

    /// <summary>Creates a successful result carrying <paramref name="value"/>.</summary>
    /// <param name="value">The parsed value.</param>
    /// <param name="context">The capture context to copy output and metadata from.</param>
    /// <param name="target">The launched target.</param>
    /// <returns>A successful <see cref="CaptureResult{T}"/>.</returns>
    public static CaptureResult<T> Success(T value, CaptureContext context, CaptureTarget target) =>
        new(
            ok: true,
            value,
            error: null,
            context.Stdout,
            context.Stderr,
            context.Output,
            context.Chunks,
            context.ExitCode,
            context.Signal,
            context.Duration,
            target);

    /// <summary>Creates a failed result carrying <paramref name="error"/>.</summary>
    /// <param name="error">The structured failure.</param>
    /// <param name="context">The capture context to copy output and metadata from.</param>
    /// <param name="target">The launched target.</param>
    /// <returns>A failed <see cref="CaptureResult{T}"/>.</returns>
    public static CaptureResult<T> Failure(CaptureFailure error, CaptureContext context, CaptureTarget target) =>
        new(
            ok: false,
            value: default,
            error,
            context.Stdout,
            context.Stderr,
            context.Output,
            context.Chunks,
            context.ExitCode,
            context.Signal,
            context.Duration,
            target);
}
