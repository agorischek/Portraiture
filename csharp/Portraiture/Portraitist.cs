using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Text;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;

namespace Portraiture;

/// <summary>
/// Runs external commands, processes, and scripts and captures a structured portrait of their
/// output. A <see cref="Portraitist"/> owns reusable defaults; per-call
/// <see cref="CaptureOptions"/> always override them.
/// </summary>
/// <remarks>
/// <para>
/// <b>Failure model.</b> Normal process failures (spawn errors, nonzero exits, stderr policy,
/// timeouts, parser exceptions) are returned as failed <see cref="CaptureResult{T}"/> values, not
/// thrown.
/// </para>
/// <para>
/// <b>Timeout versus cancellation.</b> When <see cref="CaptureOptions.Timeout"/> expires, the
/// entire child process tree is killed and a failed result with kind
/// <see cref="CaptureFailureKind.Timeout"/> is returned; output captured before the timeout stays
/// available. When the caller's <see cref="CancellationToken"/> is cancelled, the child process
/// tree is killed, resources are disposed, the stream reader tasks are observed, and then
/// <see cref="OperationCanceledException"/> is thrown — the idiomatic .NET cooperative-cancellation
/// contract. The two outcomes are reliably distinguished: if the token is cancelled, cancellation
/// wins even if the timeout elapsed at the same moment.
/// </para>
/// <para>
/// <b>Environment.</b> Supplied environment variables augment the parent environment; a
/// <see langword="null"/> dictionary value removes the key. See
/// <see cref="CaptureOptions.Environment"/>.
/// </para>
/// </remarks>
public sealed class Portraitist
{
    /// <summary>
    /// How long to keep draining stdout/stderr after the process tree has been killed. If an
    /// orphaned grandchild keeps the pipes open past this grace period, its late output is dropped.
    /// </summary>
    private static readonly TimeSpan KillDrainGracePeriod = TimeSpan.FromSeconds(2);

    private readonly PortraitistOptions defaults;
    private readonly IReadOnlyDictionary<string, CaptureInterpreter> interpreters;

    /// <summary>Creates a portraitist with an optional logger and default script interpreters.</summary>
    /// <param name="logger">Default logger for lifecycle and stream events.</param>
    /// <param name="interpreters">Default script interpreters keyed by file extension.</param>
    public Portraitist(
        ILogger? logger = null,
        IReadOnlyDictionary<string, CaptureInterpreter>? interpreters = null)
        : this(new PortraitistOptions
        {
            Logger = logger,
            Interpreters = interpreters,
        })
    {
    }

    /// <summary>Creates a portraitist with the supplied constructor defaults.</summary>
    /// <param name="options">Defaults applied to every capture made through this instance.</param>
    public Portraitist(PortraitistOptions options)
    {
        defaults = options;
        interpreters = NormalizeInterpreters(options.Interpreters);
    }

    /// <summary>Creates a portraitist from dependency-injected options.</summary>
    /// <param name="options">The options wrapper whose <see cref="IOptions{TOptions}.Value"/> supplies the defaults.</param>
    public Portraitist(IOptions<PortraitistOptions> options)
        : this(options.Value)
    {
    }

    /// <summary>Runs a shell command string and captures its output.</summary>
    /// <param name="command">The shell command line.</param>
    /// <param name="options">Per-call options; unset properties fall back to constructor defaults.</param>
    /// <param name="cancellationToken">Cancels the capture: the child process tree is killed and <see cref="OperationCanceledException"/> is thrown.</param>
    /// <returns>The capture result; without a parser the value is the combined output string.</returns>
    /// <exception cref="OperationCanceledException"><paramref name="cancellationToken"/> was cancelled.</exception>
    public Task<CaptureResult<string>> CaptureCommandAsync(
        string command,
        CaptureOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var target = new CaptureTarget(CaptureTargetKind.Command, command, Array.Empty<string>());

        return RunAsync(
            target,
            parser: static (text, _) => text,
            parserWasProvided: false,
            options,
            cancellationToken);
    }

    /// <summary>Runs a shell command string and parses its captured output.</summary>
    /// <typeparam name="T">The parsed value type.</typeparam>
    /// <param name="command">The shell command line.</param>
    /// <param name="parser">Converts captured text (stdout by default) into <typeparamref name="T"/>.</param>
    /// <param name="options">Per-call options; unset properties fall back to constructor defaults.</param>
    /// <param name="cancellationToken">Cancels the capture: the child process tree is killed and <see cref="OperationCanceledException"/> is thrown.</param>
    /// <returns>The capture result.</returns>
    /// <exception cref="OperationCanceledException"><paramref name="cancellationToken"/> was cancelled.</exception>
    public Task<CaptureResult<T>> CaptureCommandAsync<T>(
        string command,
        CaptureParser<T> parser,
        CaptureOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var target = new CaptureTarget(CaptureTargetKind.Command, command, Array.Empty<string>());

        return RunAsync(target, parser, parserWasProvided: true, options, cancellationToken);
    }

    /// <summary>Runs an executable with literal arguments (no shell interpretation by default).</summary>
    /// <param name="program">The executable to run.</param>
    /// <param name="args">Literal arguments passed to the program.</param>
    /// <param name="options">Per-call options; unset properties fall back to constructor defaults.</param>
    /// <param name="cancellationToken">Cancels the capture: the child process tree is killed and <see cref="OperationCanceledException"/> is thrown.</param>
    /// <returns>The capture result; without a parser the value is the combined output string.</returns>
    /// <exception cref="OperationCanceledException"><paramref name="cancellationToken"/> was cancelled.</exception>
    /// <exception cref="NotSupportedException"><see cref="CaptureOptions.UseShell"/> is enabled with arguments on Windows.</exception>
    public Task<CaptureResult<string>> CaptureProcessAsync(
        string program,
        IEnumerable<string>? args = null,
        CaptureOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var target = new CaptureTarget(CaptureTargetKind.Process, program, (args ?? Array.Empty<string>()).ToArray());

        return RunAsync(
            target,
            parser: static (text, _) => text,
            parserWasProvided: false,
            options,
            cancellationToken);
    }

    /// <summary>Runs an executable without arguments and parses its captured output.</summary>
    /// <typeparam name="T">The parsed value type.</typeparam>
    /// <param name="program">The executable to run.</param>
    /// <param name="parser">Converts captured text (stdout by default) into <typeparamref name="T"/>.</param>
    /// <param name="options">Per-call options; unset properties fall back to constructor defaults.</param>
    /// <param name="cancellationToken">Cancels the capture: the child process tree is killed and <see cref="OperationCanceledException"/> is thrown.</param>
    /// <returns>The capture result.</returns>
    /// <exception cref="OperationCanceledException"><paramref name="cancellationToken"/> was cancelled.</exception>
    public Task<CaptureResult<T>> CaptureProcessAsync<T>(
        string program,
        CaptureParser<T> parser,
        CaptureOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        return CaptureProcessAsync(program, args: null, parser, options, cancellationToken);
    }

    /// <summary>Runs an executable with literal arguments and parses its captured output.</summary>
    /// <typeparam name="T">The parsed value type.</typeparam>
    /// <param name="program">The executable to run.</param>
    /// <param name="args">Literal arguments passed to the program.</param>
    /// <param name="parser">Converts captured text (stdout by default) into <typeparamref name="T"/>.</param>
    /// <param name="options">Per-call options; unset properties fall back to constructor defaults.</param>
    /// <param name="cancellationToken">Cancels the capture: the child process tree is killed and <see cref="OperationCanceledException"/> is thrown.</param>
    /// <returns>The capture result.</returns>
    /// <exception cref="OperationCanceledException"><paramref name="cancellationToken"/> was cancelled.</exception>
    /// <exception cref="NotSupportedException"><see cref="CaptureOptions.UseShell"/> is enabled with arguments on Windows.</exception>
    public Task<CaptureResult<T>> CaptureProcessAsync<T>(
        string program,
        IEnumerable<string>? args,
        CaptureParser<T> parser,
        CaptureOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var target = new CaptureTarget(CaptureTargetKind.Process, program, (args ?? Array.Empty<string>()).ToArray());

        return RunAsync(target, parser, parserWasProvided: true, options, cancellationToken);
    }

    /// <summary>Runs a script file, directly or through a configured interpreter.</summary>
    /// <param name="path">The script file path.</param>
    /// <param name="args">Arguments passed to the script.</param>
    /// <param name="options">Per-call options; unset properties fall back to constructor defaults.</param>
    /// <param name="cancellationToken">Cancels the capture: the child process tree is killed and <see cref="OperationCanceledException"/> is thrown.</param>
    /// <returns>The capture result; without a parser the value is the combined output string.</returns>
    /// <exception cref="OperationCanceledException"><paramref name="cancellationToken"/> was cancelled.</exception>
    public Task<CaptureResult<string>> CaptureScriptAsync(
        string path,
        IEnumerable<string>? args = null,
        CaptureOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var target = CreateScriptTarget(path, (args ?? Array.Empty<string>()).ToArray(), options?.Interpreter ?? defaults.Interpreter);

        return RunAsync(
            target,
            parser: static (text, _) => text,
            parserWasProvided: false,
            options,
            cancellationToken);
    }

    /// <summary>Runs a script file without arguments and parses its captured output.</summary>
    /// <typeparam name="T">The parsed value type.</typeparam>
    /// <param name="path">The script file path.</param>
    /// <param name="parser">Converts captured text (stdout by default) into <typeparamref name="T"/>.</param>
    /// <param name="options">Per-call options; unset properties fall back to constructor defaults.</param>
    /// <param name="cancellationToken">Cancels the capture: the child process tree is killed and <see cref="OperationCanceledException"/> is thrown.</param>
    /// <returns>The capture result.</returns>
    /// <exception cref="OperationCanceledException"><paramref name="cancellationToken"/> was cancelled.</exception>
    public Task<CaptureResult<T>> CaptureScriptAsync<T>(
        string path,
        CaptureParser<T> parser,
        CaptureOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        return CaptureScriptAsync(path, args: null, parser, options, cancellationToken);
    }

    /// <summary>Runs a script file with arguments and parses its captured output.</summary>
    /// <typeparam name="T">The parsed value type.</typeparam>
    /// <param name="path">The script file path.</param>
    /// <param name="args">Arguments passed to the script.</param>
    /// <param name="parser">Converts captured text (stdout by default) into <typeparamref name="T"/>.</param>
    /// <param name="options">Per-call options; unset properties fall back to constructor defaults.</param>
    /// <param name="cancellationToken">Cancels the capture: the child process tree is killed and <see cref="OperationCanceledException"/> is thrown.</param>
    /// <returns>The capture result.</returns>
    /// <exception cref="OperationCanceledException"><paramref name="cancellationToken"/> was cancelled.</exception>
    public Task<CaptureResult<T>> CaptureScriptAsync<T>(
        string path,
        IEnumerable<string>? args,
        CaptureParser<T> parser,
        CaptureOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var target = CreateScriptTarget(path, (args ?? Array.Empty<string>()).ToArray(), options?.Interpreter ?? defaults.Interpreter);

        return RunAsync(target, parser, parserWasProvided: true, options, cancellationToken);
    }

    /// <summary>Runs a pre-built <see cref="CaptureTarget"/> and parses its captured output.</summary>
    /// <typeparam name="T">The parsed value type.</typeparam>
    /// <param name="target">The launch target to run.</param>
    /// <param name="parser">Converts captured text (stdout by default) into <typeparamref name="T"/>.</param>
    /// <param name="options">Per-call options; unset properties fall back to constructor defaults.</param>
    /// <param name="cancellationToken">Cancels the capture: the child process tree is killed and <see cref="OperationCanceledException"/> is thrown.</param>
    /// <returns>The capture result.</returns>
    /// <exception cref="OperationCanceledException"><paramref name="cancellationToken"/> was cancelled.</exception>
    /// <exception cref="NotSupportedException"><see cref="CaptureOptions.UseShell"/> is enabled with arguments on Windows.</exception>
    public async Task<CaptureResult<T>> RunAsync<T>(
        CaptureTarget target,
        CaptureParser<T> parser,
        CaptureOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        return await RunAsync(
            target,
            parser,
            parserWasProvided: true,
            options,
            cancellationToken).ConfigureAwait(false);
    }

    private async Task<CaptureResult<T>> RunAsync<T>(
        CaptureTarget target,
        CaptureParser<T> parser,
        bool parserWasProvided,
        CaptureOptions? options,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        var resolvedOptions = ResolveOptions(options);
        var runLogger = resolvedOptions.Logger;
        var stopwatch = Stopwatch.StartNew();
        var chunks = new List<CaptureChunk>();
        var chunksLock = new object();

        Log.Started(runLogger, target.Kind, target.Command);

        using var process = new Process
        {
            StartInfo = BuildStartInfo(target, resolvedOptions),
        };

        try
        {
            process.Start();
        }
        catch (Exception exception) when (exception is InvalidOperationException or Win32Exception)
        {
            stopwatch.Stop();
            var spawnContext = EmptyContext(stopwatch.Elapsed);
            return Fail<T>(
                runLogger,
                target,
                spawnContext,
                new CaptureFailure(
                    CaptureFailureKind.Spawn,
                    exception.Message.Length > 0 ? exception.Message : "Failed to start capture target.",
                    exception));
        }

        // Stream I/O (including stdin writing) runs concurrently with the exit wait so a timeout
        // also bounds a child that never reads its stdin. The linked source lets the kill paths
        // abandon I/O that an orphaned grandchild keeps open.
        using var ioCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);

        var stdoutTask = ReadStreamAsync(
            CaptureStream.Stdout,
            process.StandardOutput.BaseStream,
            resolvedOptions.Encoding,
            chunks,
            chunksLock,
            runLogger,
            ioCts.Token);

        var stderrTask = ReadStreamAsync(
            CaptureStream.Stderr,
            process.StandardError.BaseStream,
            resolvedOptions.Encoding,
            chunks,
            chunksLock,
            runLogger,
            ioCts.Token);

        var stdinTask = WriteStandardInputAsync(process, resolvedOptions.StandardInput, ioCts.Token);
        var ioTasks = Task.WhenAll(stdoutTask, stderrTask, stdinTask);

        bool timedOut;
        try
        {
            timedOut = await WaitForExitAsync(process, resolvedOptions.Timeout, cancellationToken)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            // User cancellation contract: kill the process tree, dispose cleanly (via the using
            // declarations above), observe the I/O tasks, then propagate OperationCanceledException.
            TryKillProcessTree(process);
            try
            {
                await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
            }
            catch (InvalidOperationException)
            {
                // The process handle is already gone; nothing left to reap.
            }

            ioCts.Cancel();
            await ObserveQuietlyAsync(ioTasks, KillDrainGracePeriod).ConfigureAwait(false);
            throw;
        }

        if (timedOut)
        {
            TryKillProcessTree(process);
            await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
            await DrainAfterKillAsync(ioTasks, ioCts).ConfigureAwait(false);
        }
        else
        {
            await ioTasks.ConfigureAwait(false);
        }

        stopwatch.Stop();

        CaptureChunk[] snapshot;
        lock (chunksLock)
        {
            snapshot = chunks.ToArray();
        }

        var frozenChunks = new ReadOnlyCollection<CaptureChunk>(snapshot);
        var stdout = string.Concat(frozenChunks.Where(chunk => chunk.Stream == CaptureStream.Stdout).Select(chunk => chunk.Text));
        var stderr = string.Concat(frozenChunks.Where(chunk => chunk.Stream == CaptureStream.Stderr).Select(chunk => chunk.Text));
        var output = string.Concat(frozenChunks.Select(chunk => chunk.Text));
        var exitCode = process.HasExited ? process.ExitCode : (int?)null;
        var context = new CaptureContext(
            stdout,
            stderr,
            output,
            frozenChunks,
            exitCode,
            InferSignal(exitCode, killedByCapture: timedOut),
            stopwatch.Elapsed);

        if (timedOut)
        {
            return Fail<T>(
                runLogger,
                target,
                context,
                new CaptureFailure(
                    CaptureFailureKind.Timeout,
                    $"Capture target timed out after {resolvedOptions.Timeout!.Value.TotalMilliseconds:0}ms."));
        }

        if (resolvedOptions.FailOnNonZeroExit && context.ExitCode != 0)
        {
            return Fail<T>(
                runLogger,
                target,
                context,
                new CaptureFailure(
                    CaptureFailureKind.Exit,
                    $"Capture target exited with code {context.ExitCode}."));
        }

        if (resolvedOptions.Stderr == CaptureStderrPolicy.Fail && stderr.Length > 0)
        {
            return Fail<T>(
                runLogger,
                target,
                context,
                new CaptureFailure(CaptureFailureKind.Stderr, "Capture target wrote to stderr."));
        }

        var parseInput = resolvedOptions.ParseInput ?? (parserWasProvided ? CaptureParseInput.Stdout : CaptureParseInput.Combined);
        var parseText = SelectText(context, parseInput);

        T value;
        try
        {
            value = parser(parseText, context);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            // A parser observing the caller's token is cancellation, not a parse failure.
            throw;
        }
        catch (Exception exception)
        {
            return Fail<T>(
                runLogger,
                target,
                context,
                new CaptureFailure(
                    CaptureFailureKind.Parse,
                    exception.Message.Length > 0 ? exception.Message : "Parser failed.",
                    exception));
        }

        Log.Succeeded(runLogger, target.Kind, target.Command, context.Duration.TotalMilliseconds, context.ExitCode);

        return CaptureResult<T>.Success(value, context, target);
    }

    private ResolvedCaptureOptions ResolveOptions(CaptureOptions? options)
    {
        options ??= new CaptureOptions();

        return new ResolvedCaptureOptions(
            WorkingDirectory: options.WorkingDirectory ?? defaults.WorkingDirectory,
            Environment: MergeEnvironment(defaults.Environment, options.Environment),
            FailOnNonZeroExit: options.FailOnNonZeroExit ?? defaults.FailOnNonZeroExit ?? true,
            Logger: options.Logger ?? defaults.Logger ?? NullLogger.Instance,
            ParseInput: options.ParseInput ?? defaults.ParseInput,
            Interpreter: options.Interpreter ?? defaults.Interpreter,
            UseShell: options.UseShell ?? defaults.UseShell,
            Stderr: options.Stderr ?? defaults.Stderr ?? CaptureStderrPolicy.Capture,
            StandardInput: options.StandardInput ?? defaults.StandardInput,
            Encoding: options.Encoding ?? defaults.Encoding ?? Encoding.UTF8,
            Timeout: options.Timeout ?? defaults.Timeout);
    }

    private static IReadOnlyDictionary<string, string?>? MergeEnvironment(
        IReadOnlyDictionary<string, string?>? defaults,
        IReadOnlyDictionary<string, string?>? overrides)
    {
        if (defaults is null && overrides is null)
        {
            return null;
        }

        var comparer = OperatingSystem.IsWindows()
            ? StringComparer.OrdinalIgnoreCase
            : StringComparer.Ordinal;
        var merged = new Dictionary<string, string?>(comparer);

        if (defaults is not null)
        {
            foreach (var (key, value) in defaults)
            {
                merged[key] = value;
            }
        }

        if (overrides is not null)
        {
            foreach (var (key, value) in overrides)
            {
                merged[key] = value;
            }
        }

        return merged;
    }

    private static ProcessStartInfo BuildStartInfo(CaptureTarget target, ResolvedCaptureOptions options)
    {
        var useShell = options.UseShell ?? target.Kind == CaptureTargetKind.Command;
        var startInfo = new ProcessStartInfo
        {
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            StandardOutputEncoding = options.Encoding,
            StandardErrorEncoding = options.Encoding,
        };

        if (options.WorkingDirectory is not null)
        {
            startInfo.WorkingDirectory = options.WorkingDirectory;
        }

        if (useShell)
        {
            ConfigureShellCommand(startInfo, target);
        }
        else
        {
            startInfo.FileName = target.Command;
            foreach (var arg in target.Args)
            {
                startInfo.ArgumentList.Add(arg);
            }
        }

        // Supplied variables augment the inherited parent environment; a null value removes the key.
        if (options.Environment is not null)
        {
            foreach (var (key, value) in options.Environment)
            {
                if (value is null)
                {
                    startInfo.Environment.Remove(key);
                }
                else
                {
                    startInfo.Environment[key] = value;
                }
            }
        }

        return startInfo;
    }

    private CaptureTarget CreateScriptTarget(
        string path,
        IReadOnlyList<string> args,
        CaptureInterpreter? explicitInterpreter)
    {
        var interpreter = explicitInterpreter ?? ResolveDefaultInterpreter(path);

        if (interpreter is null)
        {
            return new CaptureTarget(CaptureTargetKind.Script, path, args, Script: path);
        }

        return new CaptureTarget(
            CaptureTargetKind.Script,
            interpreter.Command,
            interpreter.Args.Concat(new[] { path }).Concat(args).ToArray(),
            Script: path,
            Interpreter: interpreter);
    }

    private CaptureInterpreter? ResolveDefaultInterpreter(string path)
    {
        var extension = NormalizeExtension(Path.GetExtension(path));
        if (extension is null)
        {
            return null;
        }

        return interpreters.TryGetValue(extension, out var interpreter)
            ? interpreter
            : null;
    }

    private static IReadOnlyDictionary<string, CaptureInterpreter> NormalizeInterpreters(
        IReadOnlyDictionary<string, CaptureInterpreter>? interpreters)
    {
        // Case-insensitive with last-wins semantics so ".SH" and ".sh" never throw on construction.
        var normalized = new Dictionary<string, CaptureInterpreter>(StringComparer.OrdinalIgnoreCase);

        if (interpreters is null)
        {
            return normalized;
        }

        foreach (var (key, value) in interpreters)
        {
            normalized[NormalizeExtension(key) ?? key] = value;
        }

        return normalized;
    }

    private static string? NormalizeExtension(string extension)
    {
        if (string.IsNullOrWhiteSpace(extension))
        {
            return null;
        }

        var normalized = extension.ToLowerInvariant();
        return normalized.StartsWith('.') ? normalized : $".{normalized}";
    }

    private static void ConfigureShellCommand(ProcessStartInfo startInfo, CaptureTarget target)
    {
        if (OperatingSystem.IsWindows())
        {
            if (target.Args.Count > 0)
            {
                throw new NotSupportedException(
                    "UseShell with explicit arguments is not supported on Windows because cmd.exe has no " +
                    "reliable argument quoting. Compose the full command line yourself with CaptureCommandAsync, " +
                    "or disable UseShell to pass literal arguments.");
            }

            startInfo.FileName = Environment.GetEnvironmentVariable("COMSPEC") ?? "cmd.exe";
            startInfo.ArgumentList.Add("/c");
            startInfo.ArgumentList.Add(target.Command);
        }
        else
        {
            startInfo.FileName = "/bin/sh";
            startInfo.ArgumentList.Add("-c");
            startInfo.ArgumentList.Add(ComposePosixShellCommand(target));
        }
    }

    private static string ComposePosixShellCommand(CaptureTarget target)
    {
        if (target.Kind == CaptureTargetKind.Command)
        {
            // Command targets are raw shell lines by design; they never carry separate args.
            return target.Command;
        }

        // Process/script targets carry literal arguments: single-quote everything so the shell
        // passes the program and each argument through verbatim.
        var parts = new List<string>(target.Args.Count + 1) { QuoteForPosixShell(target.Command) };
        parts.AddRange(target.Args.Select(QuoteForPosixShell));
        return string.Join(' ', parts);
    }

    private static string QuoteForPosixShell(string value) =>
        "'" + value.Replace("'", "'\\''") + "'";

    /// <summary>
    /// Waits for exit, bounded by the optional timeout and the caller's token. Returns
    /// <see langword="true"/> when the timeout expired (the caller kills the tree). Cancellation is
    /// checked before classifying a timeout, so a cancelled token always surfaces as
    /// <see cref="OperationCanceledException"/> rather than racing into a timeout result.
    /// </summary>
    private static async Task<bool> WaitForExitAsync(
        Process process,
        TimeSpan? timeout,
        CancellationToken cancellationToken)
    {
        if (timeout is null)
        {
            await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
            return false;
        }

        try
        {
            await process.WaitForExitAsync(CancellationToken.None)
                .WaitAsync(timeout.Value, cancellationToken)
                .ConfigureAwait(false);
            return false;
        }
        catch (TimeoutException)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return true;
        }
    }

    private static void TryKillProcessTree(Process process)
    {
        try
        {
            process.Kill(entireProcessTree: true);
        }
        catch (Exception exception) when (exception is InvalidOperationException or Win32Exception or NotSupportedException)
        {
            // The process exited between the wait and the kill, or the handle is gone; both benign.
        }
    }

    /// <summary>
    /// After a kill, waits briefly for the pipe readers to reach end-of-stream. If an orphaned
    /// grandchild still holds the pipes open after the grace period, reading is cancelled and any
    /// late output is dropped.
    /// </summary>
    private static async Task DrainAfterKillAsync(Task ioTasks, CancellationTokenSource ioCts)
    {
        try
        {
            await ioTasks.WaitAsync(KillDrainGracePeriod).ConfigureAwait(false);
        }
        catch (TimeoutException)
        {
            ioCts.Cancel();
            await ObserveQuietlyAsync(ioTasks, TimeSpan.FromSeconds(1)).ConfigureAwait(false);
        }
    }

    private static async Task ObserveQuietlyAsync(Task task, TimeSpan grace)
    {
        try
        {
            await task.WaitAsync(grace).ConfigureAwait(false);
        }
        catch (TimeoutException)
        {
            // A pipe-holding orphan can delay completion arbitrarily; abandon the drain but keep
            // any eventual fault observed so it never surfaces as an unobserved task exception.
            _ = task.ContinueWith(static t => _ = t.Exception, TaskScheduler.Default);
        }
    }

    private static async Task WriteStandardInputAsync(
        Process process,
        string? input,
        CancellationToken cancellationToken)
    {
        var writer = process.StandardInput;

        try
        {
            if (!string.IsNullOrEmpty(input))
            {
                await writer.WriteAsync(input.AsMemory(), cancellationToken).ConfigureAwait(false);
                await writer.FlushAsync().ConfigureAwait(false);
            }
        }
        catch (IOException)
        {
            // The child exited without draining stdin (broken pipe); ignored by design.
        }
        catch (OperationCanceledException)
        {
            // The capture was cancelled or timed out while writing; the kill path cleans up.
        }
        finally
        {
            try
            {
                await writer.DisposeAsync().ConfigureAwait(false);
            }
            catch (IOException)
            {
                // Flushing on close can also hit the broken pipe; equally ignorable.
            }
        }
    }

    private static async Task ReadStreamAsync(
        CaptureStream stream,
        Stream pipe,
        Encoding encoding,
        List<CaptureChunk> chunks,
        object chunksLock,
        ILogger logger,
        CancellationToken cancellationToken)
    {
        // A stateful decoder per stream keeps multibyte characters split across reads intact.
        var decoder = encoding.GetDecoder();
        var byteBuffer = new byte[4096];
        var charBuffer = new char[encoding.GetMaxCharCount(byteBuffer.Length)];

        while (true)
        {
            int bytesRead;
            try
            {
                bytesRead = await pipe.ReadAsync(byteBuffer.AsMemory(), cancellationToken)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                // The capture was cancelled, or a post-kill drain gave up on a held-open pipe.
                return;
            }
            catch (IOException)
            {
                // The pipe broke after a kill; treat as end of stream.
                return;
            }

            var flush = bytesRead == 0;
            var charCount = decoder.GetChars(byteBuffer, 0, bytesRead, charBuffer, 0, flush);

            if (charCount > 0)
            {
                var text = new string(charBuffer, 0, charCount);
                lock (chunksLock)
                {
                    chunks.Add(new CaptureChunk(stream, text));
                }

                if (stream == CaptureStream.Stdout)
                {
                    Log.StdoutChunk(logger, text);
                }
                else
                {
                    Log.StderrChunk(logger, text);
                }
            }

            if (flush)
            {
                return;
            }
        }
    }

    private static CaptureResult<T> Fail<T>(
        ILogger logger,
        CaptureTarget target,
        CaptureContext context,
        CaptureFailure failure)
    {
        Log.Failed(logger, failure.Cause, target.Kind, target.Command, failure.Kind, failure.Message);

        return CaptureResult<T>.Failure(failure, context, target);
    }

    /// <summary>
    /// Best-effort Unix signal inference; see <see cref="CaptureResult{T}.Signal"/> for the
    /// documented heuristic and its limitations.
    /// </summary>
    private static int? InferSignal(int? exitCode, bool killedByCapture)
    {
        if (OperatingSystem.IsWindows())
        {
            return null;
        }

        if (killedByCapture)
        {
            // The timeout path kills the tree with SIGKILL.
            return 9;
        }

        // .NET reports exit code 128 + n on Unix when the child died to signal n. A child that
        // deliberately exits with a code in this range is indistinguishable from a signal death.
        return exitCode is > 128 and <= 192 ? exitCode - 128 : null;
    }

    private static CaptureContext EmptyContext(TimeSpan duration) =>
        new(
            Stdout: string.Empty,
            Stderr: string.Empty,
            Output: string.Empty,
            Chunks: Array.Empty<CaptureChunk>(),
            ExitCode: null,
            Signal: null,
            Duration: duration);

    private static string SelectText(CaptureContext context, CaptureParseInput parseInput) =>
        parseInput switch
        {
            CaptureParseInput.Stdout => context.Stdout,
            CaptureParseInput.Stderr => context.Stderr,
            _ => context.Output,
        };
}
