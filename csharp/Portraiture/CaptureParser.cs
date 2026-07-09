namespace Portraiture;

/// <summary>
/// Converts captured text into a typed value. Selected input text (see
/// <see cref="CaptureOptions.ParseInput"/>) is passed as <paramref name="text"/>; the full capture is
/// available through <paramref name="context"/>. Exceptions thrown by a parser produce a failed result
/// with kind <see cref="CaptureFailureKind.Parse"/>.
/// </summary>
/// <typeparam name="T">The parsed value type.</typeparam>
/// <param name="text">The captured text selected by <see cref="CaptureOptions.ParseInput"/>.</param>
/// <param name="context">The full capture context (stdout, stderr, chunks, exit code, duration).</param>
/// <returns>The parsed value.</returns>
public delegate T CaptureParser<out T>(string text, CaptureContext context);
