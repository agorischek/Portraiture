# C#

```csharp
using Portraiture;
```

## Command capture

```csharp
var result = await Capture.CommandAsync("uname -a");

if (!result.Ok)
{
    throw new InvalidOperationException(result.Error.Message);
}

Console.WriteLine(result.Value);
```

## Process capture

Use `CaptureProcessAsync` when you want literal arguments without shell
interpretation:

```csharp
var portraitist = new Portraitist();
var result = await portraitist.CaptureProcessAsync("rg", ["TODO", "."]);
```

## Script capture

```csharp
var result = await portraitist.CaptureScriptAsync("./scripts/collect-host", [
    "--json",
]);
```

Use an explicit interpreter when a script path should be launched through a
specific runtime:

```csharp
await portraitist.CaptureScriptAsync(
    "./scripts/collect-host.ps1",
    ["--json"],
    new CaptureOptions
    {
        Interpreter = new CaptureInterpreter(
            "pwsh",
            ["-NoProfile", "-NonInteractive", "-File"])
    });
```

## Defaults

```csharp
var portraitist = new Portraitist(new PortraitistOptions
{
    WorkingDirectory = "/workspace/project",
    Timeout = TimeSpan.FromSeconds(5),
    Stderr = CaptureStderrPolicy.Fail,
});
```

Dependency-injection style `IOptions<PortraitistOptions>` is supported:

```csharp
using Microsoft.Extensions.Options;

var portraitist = new Portraitist(Options.Create(new PortraitistOptions
{
    WorkingDirectory = "/workspace/project",
}));
```

Default interpreters can be configured by extension:

```csharp
var portraitist = new Portraitist(
    interpreters: new Dictionary<string, CaptureInterpreter>
    {
        [".ps1"] = new("pwsh", ["-NoProfile", "-NonInteractive", "-File"]),
        [".py"] = new("python3", []),
    });
```

## Parsers

```csharp
using System.Text.Json;

var result = await portraitist.CaptureScriptAsync(
    "./scripts/collect-host-json",
    static (text, _) => JsonSerializer.Deserialize<HostPortrait>(text)!);

if (result.Ok)
{
    Console.WriteLine(result.Value.Hostname);
}

public sealed record HostPortrait(string Hostname, string Platform);
```

## ILogger

Pass an `ILogger` into `Portraitist` when you construct it:

```csharp
using Microsoft.Extensions.Logging;

using var loggerFactory = LoggerFactory.Create(builder =>
{
    builder.AddConsole();
    builder.SetMinimumLevel(LogLevel.Information);
});

var portraitist = new Portraitist(loggerFactory.CreateLogger<Portraitist>());
```

The package references `Microsoft.Extensions.Logging.Abstractions`. Your
application chooses the concrete logging provider.
