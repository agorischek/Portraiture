using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using Portraiture;
using Xunit;

namespace Portraiture.Tests;

public sealed class CaptureTests
{
    [Fact]
    public async Task CaptureCommandAsyncCapturesStdout()
    {
        var portraitist = new Portraitist();
        var result = await portraitist.CaptureCommandAsync(PrintfCommand("hello"));

        Assert.True(result.Ok);
        Assert.Equal("hello", result.Value);
        Assert.Equal("hello", result.Stdout);
        Assert.Equal("", result.Stderr);
        Assert.Equal(0, result.ExitCode);
        Assert.Equal(CaptureTargetKind.Command, result.Target.Kind);
    }

    [Fact]
    public async Task CaptureCommandFacadeDelegatesToDefaultPortraitist()
    {
        var result = await Capture.CommandAsync(PrintfCommand("facade"));

        Assert.True(result.Ok);
        Assert.Equal("facade", result.Value);
    }

    [Fact]
    public async Task CaptureProcessAsyncPassesLiteralArgs()
    {
        var portraitist = new Portraitist();
        var result = await portraitist.CaptureProcessAsync(PrintfProgram(), new[] { "%s", "hello; echo nope" });

        Assert.True(result.Ok);
        Assert.Equal("hello; echo nope", result.Value);
        Assert.Equal(CaptureTargetKind.Process, result.Target.Kind);
    }

    [Fact]
    public async Task CaptureProcessFacadeDelegatesToDefaultPortraitist()
    {
        var result = await Capture.ProcessAsync(PrintfProgram(), new[] { "%s", "facade" });

        Assert.True(result.Ok);
        Assert.Equal("facade", result.Value);
    }

    [Fact]
    public async Task CaptureScriptAsyncParsesStdoutByDefault()
    {
        if (OperatingSystem.IsWindows())
        {
            return;
        }

        var portraitist = new Portraitist();
        var script = CreateExecutableScript(
            "#!/bin/sh\n" +
            "printf 'warn\\n' >&2\n" +
            "printf '{\"Hostname\":\"local\"}'\n");

        var result = await portraitist.CaptureScriptAsync(
            script,
            static (text, _) => System.Text.Json.JsonSerializer.Deserialize<HostPortrait>(text)!);

        Assert.True(result.Ok);
        Assert.Equal("local", result.Value.Hostname);
        Assert.Equal("warn\n", result.Stderr);
        Assert.Equal(CaptureTargetKind.Script, result.Target.Kind);
    }

    [Fact]
    public async Task CaptureScriptFacadeDelegatesToDefaultPortraitist()
    {
        if (OperatingSystem.IsWindows())
        {
            return;
        }

        var script = CreateExecutableScript("#!/bin/sh\nprintf facade\n");
        var result = await Capture.ScriptAsync(script);

        Assert.True(result.Ok);
        Assert.Equal("facade", result.Value);
    }

    [Fact]
    public async Task CaptureScriptAsyncSupportsExplicitInterpreter()
    {
        if (OperatingSystem.IsWindows())
        {
            return;
        }

        var script = CreateScriptFile("explicit.portraiture-sh", "printf \"$1\"");
        var interpreter = new CaptureInterpreter("/bin/sh", Array.Empty<string>());
        var portraitist = new Portraitist();
        var result = await portraitist.CaptureScriptAsync(
            script,
            new[] { "via-interpreter" },
            new CaptureOptions { Interpreter = interpreter });

        Assert.True(result.Ok);
        Assert.Equal("via-interpreter", result.Value);
        Assert.Equal("/bin/sh", result.Target.Command);
        Assert.Equal(script, result.Target.Script);
        Assert.Equal(interpreter, result.Target.Interpreter);
    }

    [Fact]
    public async Task PortraitistSupportsDefaultInterpretersByExtension()
    {
        if (OperatingSystem.IsWindows())
        {
            return;
        }

        var script = CreateScriptFile("default.portraiture-sh", "printf \"$1\"");
        var interpreter = new CaptureInterpreter("/bin/sh", Array.Empty<string>());
        var portraitist = new Portraitist(
            interpreters: new Dictionary<string, CaptureInterpreter>
            {
                ["portraiture-sh"] = interpreter,
            });
        var result = await portraitist.CaptureScriptAsync(script, new[] { "from-default" });

        Assert.True(result.Ok);
        Assert.Equal("from-default", result.Value);
        Assert.Equal("/bin/sh", result.Target.Command);
        Assert.Equal(script, result.Target.Script);
    }

    [Fact]
    public async Task ParseInputCanParseCombinedOutput()
    {
        var portraitist = new Portraitist();
        var result = await portraitist.CaptureProcessAsync(
            PrintfProgram(),
            new[] { "%s", "{\"ok\":true}" },
            static (text, _) => System.Text.Json.JsonSerializer.Deserialize<Dictionary<string, bool>>(text)!,
            new CaptureOptions { ParseInput = CaptureParseInput.Combined });

        Assert.True(result.Ok);
        Assert.True(result.Value["ok"]);
    }

    [Fact]
    public async Task ParseInputCanParseStderr()
    {
        var portraitist = new Portraitist();
        var result = await portraitist.CaptureCommandAsync(
            "printf out; printf err >&2",
            static (text, _) => "parsed:" + text,
            new CaptureOptions { ParseInput = CaptureParseInput.Stderr });

        Assert.True(result.Ok);
        Assert.Equal("parsed:err", result.Value);
    }

    [Fact]
    public async Task ParserFailuresReturnParseErrors()
    {
        var portraitist = new Portraitist();
        var result = await portraitist.CaptureProcessAsync(
            PrintfProgram(),
            new[] { "%s", "not-json" },
            static (text, _) => System.Text.Json.JsonSerializer.Deserialize<Dictionary<string, bool>>(text)!);

        Assert.False(result.Ok);
        Assert.Equal(CaptureFailureKind.Parse, result.Error.Kind);
        Assert.Equal("not-json", result.Stdout);
    }

    [Fact]
    public async Task StderrCanFailResult()
    {
        var portraitist = new Portraitist();
        var result = await portraitist.CaptureCommandAsync(
            StderrCommand("warn"),
            new CaptureOptions { Stderr = CaptureStderrPolicy.Fail });

        Assert.False(result.Ok);
        Assert.Equal(CaptureFailureKind.Stderr, result.Error.Kind);
        Assert.Equal("warn", result.Stderr);
    }

    [Fact]
    public async Task NonzeroExitsFailByDefault()
    {
        var portraitist = new Portraitist();
        var result = await portraitist.CaptureCommandAsync("printf before; exit 7");

        Assert.False(result.Ok);
        Assert.Equal(CaptureFailureKind.Exit, result.Error.Kind);
        Assert.Equal(7, result.ExitCode);
        Assert.Equal("before", result.Stdout);
    }

    [Fact]
    public async Task NonzeroExitsCanBeCollectedAsSuccess()
    {
        var result = await Capture.CommandAsync(
            "printf data; exit 7",
            new CaptureOptions { FailOnNonZeroExit = false });

        Assert.True(result.Ok);
        Assert.Equal(7, result.ExitCode);
        Assert.Equal("data", result.Value);
    }

    [Fact]
    public async Task TimeoutsReturnTimeoutFailureAndPreserveOutput()
    {
        var result = await Capture.CommandAsync(
            "printf before; sleep 5",
            new CaptureOptions { Timeout = TimeSpan.FromMilliseconds(50) });

        Assert.False(result.Ok);
        Assert.Equal(CaptureFailureKind.Timeout, result.Error.Kind);
        Assert.Equal("before", result.Stdout);
    }

    [Fact]
    public async Task SpawnErrorsReturnSpawnFailure()
    {
        var result = await Capture.ProcessAsync("__portraiture_missing_executable__");

        Assert.False(result.Ok);
        Assert.Equal(CaptureFailureKind.Spawn, result.Error.Kind);
    }

    [Fact]
    public async Task StandardInputIsSentToProcess()
    {
        var result = await Capture.ProcessAsync(CatProgram(), options: new CaptureOptions { StandardInput = "hello stdin" });

        Assert.True(result.Ok);
        Assert.Equal("hello stdin", result.Value);
    }

    [Fact]
    public async Task StandardInputBrokenPipeDoesNotThrowRawException()
    {
        var result = await Capture.CommandAsync(
            "exit 0",
            new CaptureOptions { StandardInput = new string('x', 1_000_000) });

        Assert.True(result.Ok);
    }

    [Fact]
    public async Task ILoggerReceivesLifecycleAndStreamLogs()
    {
        if (OperatingSystem.IsWindows())
        {
            return;
        }

        var logger = new RecordingLogger();
        var portraitist = new Portraitist(logger);
        var script = CreateExecutableScript("#!/bin/sh\nprintf 'out\\n'\nprintf 'err\\n' >&2\n");
        var result = await portraitist.CaptureScriptAsync(script);

        Assert.True(result.Ok);
        Assert.Contains("Started", logger.EventNames);
        Assert.Contains("Stdout", logger.EventNames);
        Assert.Contains("Stderr", logger.EventNames);
        Assert.Contains("Succeeded", logger.EventNames);
    }

    [Fact]
    public async Task ILoggerExceptionsDoNotChangeCaptureResult()
    {
        var portraitist = new Portraitist(new ThrowingLogger());
        var result = await portraitist.CaptureCommandAsync(PrintfCommand("ok"));

        Assert.True(result.Ok);
        Assert.Equal("ok", result.Value);
    }

    [Fact]
    public async Task EnvironmentAugmentsParentAndPerCallOverridesConstructor()
    {
        var portraitist = new Portraitist(new PortraitistOptions
        {
            Environment = new Dictionary<string, string?>
            {
                ["PORTRAITURE_A"] = "default",
                ["PORTRAITURE_B"] = "kept",
            },
        });

        var result = await portraitist.CaptureCommandAsync(
            "printf \"$PORTRAITURE_A|$PORTRAITURE_B|${PATH:+path}\"",
            new CaptureOptions
            {
                Environment = new Dictionary<string, string?>
                {
                    ["PORTRAITURE_A"] = "override",
                },
            });

        Assert.True(result.Ok);
        Assert.Equal("override|kept|path", result.Value);
    }

    [Fact]
    public async Task UseShellTrueIncludesProcessArguments()
    {
        var result = await Capture.ProcessAsync(
            PrintfProgram(),
            new[] { "%s", "shell args" },
            new CaptureOptions { UseShell = true });

        Assert.True(result.Ok);
        Assert.Equal("shell args", result.Value);
    }

    [Fact]
    public async Task DirectOptionsDefaultWorkingDirectory()
    {
        var directory = CreateTempDirectory();
        WriteMarker(directory, "direct");
        var portraitist = new Portraitist(new PortraitistOptions { WorkingDirectory = directory });
        var result = await portraitist.CaptureCommandAsync(ReadMarkerCommand());

        Assert.True(result.Ok);
        Assert.Equal("direct", result.Value.Trim());
    }

    [Fact]
    public async Task IOptionsDefaultWorkingDirectory()
    {
        var directory = CreateTempDirectory();
        WriteMarker(directory, "ioptions");
        var portraitist = new Portraitist(Options.Create(new PortraitistOptions { WorkingDirectory = directory }));
        var result = await portraitist.CaptureCommandAsync(ReadMarkerCommand());

        Assert.True(result.Ok);
        Assert.Equal("ioptions", result.Value.Trim());
    }

    [Fact]
    public async Task PerCallWorkingDirectoryOverridesPortraitistOptions()
    {
        var defaultDirectory = CreateTempDirectory();
        var overrideDirectory = CreateTempDirectory();
        WriteMarker(defaultDirectory, "default");
        WriteMarker(overrideDirectory, "override");
        var portraitist = new Portraitist(new PortraitistOptions { WorkingDirectory = defaultDirectory });
        var result = await portraitist.CaptureCommandAsync(
            ReadMarkerCommand(),
            new CaptureOptions { WorkingDirectory = overrideDirectory });

        Assert.True(result.Ok);
        Assert.Equal("override", result.Value.Trim());
    }

    private static string PrintfProgram() => OperatingSystem.IsWindows() ? "cmd.exe" : "/usr/bin/printf";

    private static string PrintfCommand(string text) => OperatingSystem.IsWindows()
        ? $"<nul set /p dummy={text}"
        : $"printf {ShellQuote(text)}";

    private static string StderrCommand(string text) => OperatingSystem.IsWindows()
        ? $"<nul set /p dummy={text} 1>&2"
        : $"printf {ShellQuote(text)} >&2";

    private static string CatProgram() => OperatingSystem.IsWindows() ? "cmd.exe" : "/bin/cat";

    private static string ReadMarkerCommand() => OperatingSystem.IsWindows() ? "type marker.txt" : "cat marker.txt";

    private static string ShellQuote(string text) => "'" + text.Replace("'", "'\"'\"'") + "'";

    private static void WriteMarker(string directory, string text) => File.WriteAllText(Path.Combine(directory, "marker.txt"), text);

    private static string CreateExecutableScript(string contents)
    {
        var path = Path.Combine(Path.GetTempPath(), $"portraiture-test-{Guid.NewGuid():N}.sh");
        File.WriteAllText(path, contents);
        File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        return path;
    }

    private static string CreateScriptFile(string name, string contents)
    {
        var directory = Path.Combine(Path.GetTempPath(), $"portraiture-test-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, name);
        File.WriteAllText(path, contents);
        return path;
    }

    private static string CreateTempDirectory()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"portraiture-cwd-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        return directory;
    }

    private sealed record HostPortrait(string Hostname);

    private sealed class RecordingLogger : ILogger
    {
        private readonly object gate = new();
        private readonly List<string> eventNames = [];

        public IReadOnlyList<string> EventNames
        {
            get
            {
                lock (gate)
                {
                    return eventNames.ToArray();
                }
            }
        }

        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;

        public bool IsEnabled(LogLevel logLevel) => true;

        public void Log<TState>(
            LogLevel logLevel,
            EventId eventId,
            TState state,
            Exception? exception,
            Func<TState, Exception?, string> formatter)
        {
            lock (gate)
            {
                eventNames.Add(eventId.Name ?? "");
            }
        }
    }

    private sealed class ThrowingLogger : ILogger
    {
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;

        public bool IsEnabled(LogLevel logLevel) => true;

        public void Log<TState>(
            LogLevel logLevel,
            EventId eventId,
            TState state,
            Exception? exception,
            Func<TState, Exception?, string> formatter)
        {
            throw new InvalidOperationException("logger failed");
        }
    }
}
