using Microsoft.Extensions.Logging;

namespace Portraiture;

/// <summary>
/// Source-generated, guarded logging for capture runs. Every internal entry point swallows logger
/// exceptions so a misbehaving <see cref="ILogger"/> can never change a capture result
/// (REQUIREMENTS.md: "Logger exceptions or failures should not change the capture result").
/// </summary>
internal static partial class Log
{
    [LoggerMessage(
        EventId = 1000,
        EventName = nameof(CaptureLogEvents.Started),
        Level = LogLevel.Information,
        Message = "Starting capture {TargetKind}: {Command}")]
    private static partial void StartedCore(ILogger logger, CaptureTargetKind targetKind, string command);

    [LoggerMessage(
        EventId = 1001,
        EventName = nameof(CaptureLogEvents.Stdout),
        Level = LogLevel.Trace,
        Message = "Capture stdout: {Text}")]
    private static partial void StdoutChunkCore(ILogger logger, string text);

    [LoggerMessage(
        EventId = 1002,
        EventName = nameof(CaptureLogEvents.Stderr),
        Level = LogLevel.Trace,
        Message = "Capture stderr: {Text}")]
    private static partial void StderrChunkCore(ILogger logger, string text);

    [LoggerMessage(
        EventId = 1003,
        EventName = nameof(CaptureLogEvents.Succeeded),
        Level = LogLevel.Information,
        Message = "Capture {TargetKind}: {Command} succeeded in {DurationMs}ms with exit code {ExitCode}")]
    private static partial void SucceededCore(
        ILogger logger,
        CaptureTargetKind targetKind,
        string command,
        double durationMs,
        int? exitCode);

    [LoggerMessage(
        EventId = 1004,
        EventName = nameof(CaptureLogEvents.Failed),
        Level = LogLevel.Warning,
        Message = "Capture {TargetKind}: {Command} failed with {FailureKind}: {FailureMessage}")]
    private static partial void FailedCore(
        ILogger logger,
        Exception? cause,
        CaptureTargetKind targetKind,
        string command,
        CaptureFailureKind failureKind,
        string failureMessage);

    internal static void Started(ILogger logger, CaptureTargetKind targetKind, string command)
    {
        try
        {
            StartedCore(logger, targetKind, command);
        }
        catch
        {
            // Logger failures must never change the capture result.
        }
    }

    internal static void StdoutChunk(ILogger logger, string text)
    {
        try
        {
            StdoutChunkCore(logger, text);
        }
        catch
        {
            // Logger failures must never change the capture result.
        }
    }

    internal static void StderrChunk(ILogger logger, string text)
    {
        try
        {
            StderrChunkCore(logger, text);
        }
        catch
        {
            // Logger failures must never change the capture result.
        }
    }

    internal static void Succeeded(
        ILogger logger,
        CaptureTargetKind targetKind,
        string command,
        double durationMs,
        int? exitCode)
    {
        try
        {
            SucceededCore(logger, targetKind, command, durationMs, exitCode);
        }
        catch
        {
            // Logger failures must never change the capture result.
        }
    }

    internal static void Failed(
        ILogger logger,
        Exception? cause,
        CaptureTargetKind targetKind,
        string command,
        CaptureFailureKind failureKind,
        string failureMessage)
    {
        try
        {
            FailedCore(logger, cause, targetKind, command, failureKind, failureMessage);
        }
        catch
        {
            // Logger failures must never change the capture result.
        }
    }
}
