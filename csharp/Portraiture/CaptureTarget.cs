namespace Portraiture;

/// <summary>
/// Describes an interpreter used to launch a script: a command plus fixed arguments that are
/// placed before the script path.
/// </summary>
/// <param name="Command">The interpreter executable, for example <c>"pwsh"</c> or <c>"/bin/sh"</c>.</param>
/// <param name="Args">Fixed arguments inserted between the interpreter command and the script path.</param>
public sealed record CaptureInterpreter(string Command, IReadOnlyList<string> Args);

/// <summary>
/// The fully resolved launch target of a capture: what will be executed and how.
/// </summary>
/// <param name="Kind">Which capture entry point produced this target.</param>
/// <param name="Command">
/// The command that is launched. For <see cref="CaptureTargetKind.Command"/> this is the raw shell
/// command string; for <see cref="CaptureTargetKind.Process"/> it is the executable; for
/// <see cref="CaptureTargetKind.Script"/> it is either the script path or the interpreter command.
/// </param>
/// <param name="Args">Literal arguments passed to <paramref name="Command"/>. Empty for command targets.</param>
/// <param name="Script">The script path for script targets; otherwise <see langword="null"/>.</param>
/// <param name="Interpreter">The interpreter used to launch the script, if any.</param>
public sealed record CaptureTarget(
    CaptureTargetKind Kind,
    string Command,
    IReadOnlyList<string> Args,
    string? Script = null,
    CaptureInterpreter? Interpreter = null);
