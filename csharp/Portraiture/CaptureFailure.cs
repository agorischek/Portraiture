namespace Portraiture;

/// <summary>Structured description of why a capture failed.</summary>
/// <param name="Kind">The failure classification.</param>
/// <param name="Message">A human-readable failure message.</param>
/// <param name="Cause">The underlying exception, when the failure was caused by one.</param>
public sealed record CaptureFailure(CaptureFailureKind Kind, string Message, Exception? Cause = null);
