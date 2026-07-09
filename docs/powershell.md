# PowerShell

Import the module from the repository:

```powershell
Import-Module ./powershell/Portraiture/Portraiture.psd1
```

## Command capture

```powershell
$result = Invoke-PortraitureCommand "[Console]::Out.Write('hello')"

if ($result.Ok) {
    $result.Value
} else {
    throw $result.Error.Message
}
```

## Process capture

Use `Invoke-PortraitureProcess` when you want literal arguments without shell
interpretation:

```powershell
$result = Invoke-PortraitureProcess "rg" -ArgumentList @("TODO", ".")
```

## Script capture

```powershell
$result = Invoke-PortraitureScript "./scripts/collect-host" `
    -ArgumentList @("--json")
```

Use an explicit interpreter when a script path should be launched through a
specific runtime:

```powershell
$result = Invoke-PortraitureScript "./scripts/collect-host.ps1" `
    -ArgumentList @("--json") `
    -Interpreter @{
        Command = "pwsh"
        Arguments = @("-NoProfile", "-NonInteractive", "-File")
    }
```

## Defaults

```powershell
$portraiture = New-Portraiture `
    -WorkingDirectory "/workspace/project" `
    -TimeoutMilliseconds 5000 `
    -StderrPolicy Fail

$result = Invoke-PortraitureCommand "git status --short" -Portraiture $portraiture
```

Default interpreters can be configured by extension:

```powershell
$portraiture = New-Portraiture -Interpreters @{
    ".ps1" = @{
        Command = "pwsh"
        Arguments = @("-NoProfile", "-NonInteractive", "-File")
    }
    ".py" = "python3"
}
```

## Parsers

```powershell
$result = Invoke-PortraitureScript "./scripts/collect-host.ps1" `
    -Interpreter @{
        Command = "pwsh"
        Arguments = @("-NoProfile", "-NonInteractive", "-File")
    } `
    -Parser {
        param($Text, $Context)
        $Text | ConvertFrom-Json
    }

$result.Value.Hostname
```

Nonzero exits fail by default. Use `-AllowNonzeroExit` when nonzero status is
expected data.
