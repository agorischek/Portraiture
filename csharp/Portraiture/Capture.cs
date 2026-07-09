namespace Portraiture;

/// <summary>
/// Static convenience facade backed by a default <see cref="Portraitist"/> instance.
/// </summary>
public static class Capture
{
    private static readonly Portraitist Default = new();

    /// <summary>Runs a shell command string and captures its output.</summary>
    public static Task<CaptureResult<string>> CommandAsync(
        string command,
        CaptureOptions? options = null,
        CancellationToken cancellationToken = default) =>
        Default.CaptureCommandAsync(command, options, cancellationToken);

    /// <summary>Runs a shell command string and parses its captured output.</summary>
    public static Task<CaptureResult<T>> CommandAsync<T>(
        string command,
        CaptureParser<T> parser,
        CaptureOptions? options = null,
        CancellationToken cancellationToken = default) =>
        Default.CaptureCommandAsync(command, parser, options, cancellationToken);

    /// <summary>Runs an executable with literal arguments and captures its output.</summary>
    public static Task<CaptureResult<string>> ProcessAsync(
        string program,
        IEnumerable<string>? args = null,
        CaptureOptions? options = null,
        CancellationToken cancellationToken = default) =>
        Default.CaptureProcessAsync(program, args, options, cancellationToken);

    /// <summary>Runs an executable without arguments and parses its captured output.</summary>
    public static Task<CaptureResult<T>> ProcessAsync<T>(
        string program,
        CaptureParser<T> parser,
        CaptureOptions? options = null,
        CancellationToken cancellationToken = default) =>
        Default.CaptureProcessAsync(program, parser, options, cancellationToken);

    /// <summary>Runs an executable with literal arguments and parses its captured output.</summary>
    public static Task<CaptureResult<T>> ProcessAsync<T>(
        string program,
        IEnumerable<string>? args,
        CaptureParser<T> parser,
        CaptureOptions? options = null,
        CancellationToken cancellationToken = default) =>
        Default.CaptureProcessAsync(program, args, parser, options, cancellationToken);

    /// <summary>Runs a script file directly or through a configured per-call interpreter.</summary>
    public static Task<CaptureResult<string>> ScriptAsync(
        string path,
        IEnumerable<string>? args = null,
        CaptureOptions? options = null,
        CancellationToken cancellationToken = default) =>
        Default.CaptureScriptAsync(path, args, options, cancellationToken);

    /// <summary>Runs a script file without arguments and parses its captured output.</summary>
    public static Task<CaptureResult<T>> ScriptAsync<T>(
        string path,
        CaptureParser<T> parser,
        CaptureOptions? options = null,
        CancellationToken cancellationToken = default) =>
        Default.CaptureScriptAsync(path, parser, options, cancellationToken);

    /// <summary>Runs a script file with arguments and parses its captured output.</summary>
    public static Task<CaptureResult<T>> ScriptAsync<T>(
        string path,
        IEnumerable<string>? args,
        CaptureParser<T> parser,
        CaptureOptions? options = null,
        CancellationToken cancellationToken = default) =>
        Default.CaptureScriptAsync(path, args, parser, options, cancellationToken);
}
