namespace Portraiture;

/// <summary>
/// Constructor defaults for a <see cref="Portraitist"/>. Every <see cref="CaptureOptions"/> property
/// set here becomes the default for captures made through that instance; per-call options always win.
/// Also usable through <c>IOptions&lt;PortraitistOptions&gt;</c> for dependency-injection scenarios.
/// </summary>
public sealed class PortraitistOptions : CaptureOptions
{
    /// <summary>
    /// Default script interpreters keyed by file extension (with or without the leading dot).
    /// Extensions are normalized case-insensitively; when two keys collide after normalization
    /// (for example <c>".SH"</c> and <c>".sh"</c>), the entry enumerated last wins.
    /// </summary>
    public IReadOnlyDictionary<string, CaptureInterpreter>? Interpreters { get; init; }
}
