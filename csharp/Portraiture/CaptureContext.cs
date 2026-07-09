namespace Portraiture;

/// <summary>A single piece of output read from the child process, in arrival order.</summary>
/// <param name="Stream">Which stream the text was read from.</param>
/// <param name="Text">The decoded text of the chunk.</param>
public sealed record CaptureChunk(CaptureStream Stream, string Text);

/// <summary>
/// Everything captured from a completed (or terminated) child process. This is also the second
/// argument supplied to <see cref="CaptureParser{T}"/> callbacks.
/// </summary>
/// <param name="Stdout">All captured standard output.</param>
/// <param name="Stderr">All captured standard error.</param>
/// <param name="Output">Stdout and stderr chunks concatenated in arrival order.</param>
/// <param name="Chunks">The individual output chunks in arrival order.</param>
/// <param name="ExitCode">The process exit code, or <see langword="null"/> if the process never started or never exited.</param>
/// <param name="Signal">
/// The Unix signal number that terminated the process, when it can be determined; see
/// <see cref="CaptureResult{T}.Signal"/> for the heuristic and its limitations. Always
/// <see langword="null"/> on Windows.
/// </param>
/// <param name="Duration">Wall-clock duration of the capture.</param>
public sealed record CaptureContext(
    string Stdout,
    string Stderr,
    string Output,
    IReadOnlyList<CaptureChunk> Chunks,
    int? ExitCode,
    int? Signal,
    TimeSpan Duration);
