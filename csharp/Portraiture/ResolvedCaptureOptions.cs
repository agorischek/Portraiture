using System.Text;
using Microsoft.Extensions.Logging;

namespace Portraiture;

internal sealed record ResolvedCaptureOptions(
    string? WorkingDirectory,
    IReadOnlyDictionary<string, string?>? Environment,
    bool FailOnNonZeroExit,
    ILogger Logger,
    CaptureParseInput? ParseInput,
    CaptureInterpreter? Interpreter,
    bool? UseShell,
    CaptureStderrPolicy Stderr,
    string? StandardInput,
    Encoding Encoding,
    TimeSpan? Timeout);
