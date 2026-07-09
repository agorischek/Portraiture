# Go

```go
import (
	"context"
	"fmt"
	"time"

	portraiture "github.com/agorischek/Portraiture/go"
)
```

## Command capture

```go
portraitist := portraiture.New(portraiture.Options{
	WorkingDirectory: "/workspace/project",
	Timeout:          5 * time.Second,
})

result := portraitist.CaptureCommand(context.Background(), "uname -a")
if !result.Ok {
	panic(result.Error.Message)
}

fmt.Println(result.Value)
```

## Process capture

Use `CaptureProcess` when you want literal arguments without shell
interpretation:

```go
result := portraitist.CaptureProcess(
	context.Background(),
	"rg",
	[]string{"TODO", "."},
)
```

## Script capture

```go
result := portraitist.CaptureScript(
	context.Background(),
	"./scripts/collect-host",
	[]string{"--json"},
)
```

Use an explicit interpreter when a script path should be launched through a
specific runtime:

```go
result := portraitist.CaptureScript(
	context.Background(),
	"./scripts/collect-host.ps1",
	[]string{"--json"},
	portraiture.Options{
		Interpreter: &portraiture.Interpreter{
			Command: "pwsh",
			Args:    []string{"-NoProfile", "-NonInteractive", "-File"},
		},
	},
)
```

Default interpreters can be configured by extension:

```go
portraitist := portraiture.New(portraiture.Options{
	Interpreters: map[string]portraiture.Interpreter{
		".ps1": {Command: "pwsh", Args: []string{"-NoProfile", "-NonInteractive", "-File"}},
		".py":  {Command: "python3"},
	},
})
```

## Parsers

Go uses a generic parsed-capture wrapper because Go does not support generic
methods.

```go
type HostPortrait struct {
	Hostname string `json:"hostname"`
	Platform string `json:"platform"`
}

result := portraiture.WithParser(
	portraitist,
	func(text string, _ portraiture.CaptureContext) (HostPortrait, error) {
		var value HostPortrait
		err := json.Unmarshal([]byte(text), &value)
		return value, err
	},
).Script(context.Background(), "./scripts/collect-host-json", nil)
```

## Cancellation and timeouts

Use `context.Context` for cancellation. A context deadline is reported as a
timeout failure.
