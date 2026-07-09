Set-StrictMode -Version Latest

if (-not ('Portraiture.StdinWriter' -as [type])) {
    Add-Type -TypeDefinition @'
using System.IO;
using System.Threading.Tasks;

namespace Portraiture
{
    public static class StdinWriter
    {
        // Writes stdin text on a background task so a child that never reads
        // stdin cannot block the capture, and swallows broken-pipe errors so a
        // child that exits without reading stdin never throws a raw exception
        // out of the capture API.
        public static Task WriteAndCloseAsync(StreamWriter writer, string text)
        {
            return Task.Run(() =>
            {
                try
                {
                    if (!string.IsNullOrEmpty(text))
                    {
                        writer.Write(text);
                    }
                }
                catch (IOException) { }
                catch (System.ObjectDisposedException) { }
                finally
                {
                    try { writer.Close(); }
                    catch (IOException) { }
                    catch (System.ObjectDisposedException) { }
                }
            });
        }
    }
}
'@
}

function New-PortraitureInterpreter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Command,

        [Parameter(Position = 1)]
        [string[]] $ArgumentList = @()
    )

    $interpreter = [pscustomobject]@{
        Command = $Command
        Arguments = @($ArgumentList)
    }
    $interpreter.PSTypeNames.Insert(0, 'Portraiture.Interpreter')
    $interpreter
}

function New-Portraiture {
    [CmdletBinding()]
    param(
        [string] $WorkingDirectory,
        [hashtable] $Environment,
        [bool] $FailOnNonzeroExit = $true,
        [switch] $AllowNonzeroExit,
        [scriptblock] $Logger,
        [ValidateSet('Stdout', 'Stderr', 'Combined')]
        [string] $ParseInput = 'Stdout',
        [bool] $UseShell,
        [ValidateSet('Capture', 'Fail')]
        [string] $StderrPolicy = 'Capture',
        [string] $StandardInput,
        [int] $TimeoutMilliseconds,
        [object] $Interpreter,
        [hashtable] $Interpreters
    )

    if ($PSBoundParameters.ContainsKey('AllowNonzeroExit') -and $AllowNonzeroExit.IsPresent -and
        $PSBoundParameters.ContainsKey('FailOnNonzeroExit')) {
        throw 'Use either -AllowNonzeroExit or -FailOnNonzeroExit, not both.'
    }

    $failOnNonzero = if ($AllowNonzeroExit.IsPresent) { $false } else { $FailOnNonzeroExit }

    $config = [pscustomobject]@{
        WorkingDirectory = $WorkingDirectory
        Environment = Copy-PortraitureHashtable $Environment
        FailOnNonzeroExit = $failOnNonzero
        Logger = $Logger
        ParseInput = $ParseInput
        UseShell = if ($PSBoundParameters.ContainsKey('UseShell')) { $UseShell } else { $null }
        StderrPolicy = $StderrPolicy
        StandardInput = if ($PSBoundParameters.ContainsKey('StandardInput')) { $StandardInput } else { $null }
        TimeoutMilliseconds = if ($PSBoundParameters.ContainsKey('TimeoutMilliseconds')) { $TimeoutMilliseconds } else { $null }
        Interpreter = ConvertTo-PortraitureInterpreter $Interpreter
        Interpreters = ConvertTo-PortraitureInterpreterMap $Interpreters
    }
    $config.PSTypeNames.Insert(0, 'Portraiture.Config')
    $config
}

function Invoke-PortraitureCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Command,

        [object] $Portraiture,
        [string] $WorkingDirectory,
        [hashtable] $Environment,
        [bool] $FailOnNonzeroExit,
        [switch] $AllowNonzeroExit,
        [scriptblock] $Logger,
        [ValidateSet('Stdout', 'Stderr', 'Combined')]
        [string] $ParseInput,
        [scriptblock] $Parser,
        [bool] $UseShell,
        [ValidateSet('Capture', 'Fail')]
        [string] $StderrPolicy,
        [string] $StandardInput,
        [int] $TimeoutMilliseconds
    )

    $config = Resolve-PortraitureConfig $Portraiture
    $target = New-PortraitureTarget -Kind 'Command' -Command $Command -ArgumentList @()
    $options = Resolve-PortraitureOptions -Config $config -Kind 'Command' -BoundParameters $PSBoundParameters
    Invoke-PortraitureCapture -Target $target -Options $options
}

function Invoke-PortraitureProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $FilePath,

        [Parameter(Position = 1)]
        [string[]] $ArgumentList = @(),

        [object] $Portraiture,
        [string] $WorkingDirectory,
        [hashtable] $Environment,
        [bool] $FailOnNonzeroExit,
        [switch] $AllowNonzeroExit,
        [scriptblock] $Logger,
        [ValidateSet('Stdout', 'Stderr', 'Combined')]
        [string] $ParseInput,
        [scriptblock] $Parser,
        [bool] $UseShell,
        [ValidateSet('Capture', 'Fail')]
        [string] $StderrPolicy,
        [string] $StandardInput,
        [int] $TimeoutMilliseconds
    )

    $config = Resolve-PortraitureConfig $Portraiture
    $target = New-PortraitureTarget -Kind 'Process' -Command $FilePath -ArgumentList $ArgumentList
    $options = Resolve-PortraitureOptions -Config $config -Kind 'Process' -BoundParameters $PSBoundParameters
    Invoke-PortraitureCapture -Target $target -Options $options
}

function Invoke-PortraitureScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Path,

        [Parameter(Position = 1)]
        [string[]] $ArgumentList = @(),

        [object] $Portraiture,
        [string] $WorkingDirectory,
        [hashtable] $Environment,
        [bool] $FailOnNonzeroExit,
        [switch] $AllowNonzeroExit,
        [scriptblock] $Logger,
        [ValidateSet('Stdout', 'Stderr', 'Combined')]
        [string] $ParseInput,
        [scriptblock] $Parser,
        [object] $Interpreter,
        [bool] $UseShell,
        [ValidateSet('Capture', 'Fail')]
        [string] $StderrPolicy,
        [string] $StandardInput,
        [int] $TimeoutMilliseconds
    )

    $config = Resolve-PortraitureConfig $Portraiture
    $callInterpreter = if ($PSBoundParameters.ContainsKey('Interpreter')) {
        ConvertTo-PortraitureInterpreter $Interpreter
    } else {
        $null
    }
    $resolvedInterpreter = Resolve-PortraitureInterpreter -Config $config -Path $Path -CallInterpreter $callInterpreter

    if ($null -eq $resolvedInterpreter) {
        $target = New-PortraitureTarget -Kind 'Script' -Command $Path -ArgumentList $ArgumentList -Script $Path
    } else {
        $scriptArguments = @($resolvedInterpreter.Arguments) + @($Path) + @($ArgumentList)
        $target = New-PortraitureTarget `
            -Kind 'Script' `
            -Command $resolvedInterpreter.Command `
            -ArgumentList $scriptArguments `
            -Script $Path `
            -Interpreter $resolvedInterpreter
    }

    $options = Resolve-PortraitureOptions -Config $config -Kind 'Script' -BoundParameters $PSBoundParameters
    Invoke-PortraitureCapture -Target $target -Options $options
}

function Invoke-PortraitureCapture {
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Target,

        [Parameter(Mandatory)]
        [pscustomobject] $Options
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-PortraitureLogger $Options.Logger ([pscustomobject]@{
        Type = 'Start'
        Target = $Target
    })

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = New-PortraitureStartInfo -Target $Target -Options $Options

    try {
        [void] $process.Start()
    } catch {
        $stopwatch.Stop()
        $context = New-PortraitureContext -Stdout '' -Stderr '' -ExitCode $null -DurationMs $stopwatch.ElapsedMilliseconds
        return New-PortraitureFailureResult -Target $Target -Context $context -Kind 'Spawn' -Message $_.Exception.Message -Cause $_.Exception -Logger $Options.Logger
    }

    # StreamReader-based reads keep multi-byte characters intact even when the
    # raw bytes arrive split across pipe chunks: the reader's decoder is stateful.
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    # Stdin is written on a background task; see Portraiture.StdinWriter.
    $stdinTask = [Portraiture.StdinWriter]::WriteAndCloseAsync($process.StandardInput, [string] $Options.StandardInput)

    $timedOut = $false
    if ($null -ne $Options.TimeoutMilliseconds -and $Options.TimeoutMilliseconds -gt 0) {
        if (-not $process.WaitForExit($Options.TimeoutMilliseconds)) {
            # The wait can expire in the same instant the process exits. Only
            # report a timeout when the process is genuinely still running.
            if ($process.HasExited) {
                $timedOut = $false
            } else {
                $timedOut = $true
                Stop-PortraitureProcess $process
            }
        }
    } else {
        $process.WaitForExit()
    }

    if ($timedOut) {
        # The process tree was killed; give the readers a bounded moment to
        # drain output that was produced before the timeout. If a leaked
        # descendant still holds the pipes open, do not hang past the deadline.
        try {
            [void] [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask), 2000)
        } catch {
        }
        $stdout = if ($stdoutTask.IsCompletedSuccessfully) { $stdoutTask.Result } else { '' }
        $stderr = if ($stderrTask.IsCompletedSuccessfully) { $stderrTask.Result } else { '' }
    } else {
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
    }

    # Observe the stdin task briefly; its own error handling swallows pipe errors.
    try {
        [void] $stdinTask.Wait(500)
    } catch {
    }

    $exitCode = if ($process.HasExited) { $process.ExitCode } else { $null }
    $stopwatch.Stop()

    $context = New-PortraitureContext `
        -Stdout $stdout `
        -Stderr $stderr `
        -ExitCode $exitCode `
        -DurationMs $stopwatch.ElapsedMilliseconds

    foreach ($chunk in $context.Chunks) {
        Invoke-PortraitureLogger $Options.Logger ([pscustomobject]@{
            Type = if ($chunk.Stream -eq 'Stdout') { 'Stdout' } else { 'Stderr' }
            Target = $Target
            Text = $chunk.Text
        })
    }

    if ($timedOut) {
        return New-PortraitureFailureResult -Target $Target -Context $context -Kind 'Timeout' -Message 'Capture timed out.' -Cause $null -Logger $Options.Logger
    }

    if ($Options.StderrPolicy -eq 'Fail' -and $context.Stderr.Length -gt 0) {
        return New-PortraitureFailureResult -Target $Target -Context $context -Kind 'Stderr' -Message 'Capture wrote to stderr.' -Cause $null -Logger $Options.Logger
    }

    if ($Options.FailOnNonzeroExit -and $null -ne $context.ExitCode -and $context.ExitCode -ne 0) {
        return New-PortraitureFailureResult `
            -Target $Target `
            -Context $context `
            -Kind 'Exit' `
            -Message "Capture exited with code $($context.ExitCode)." `
            -Cause $null `
            -Logger $Options.Logger
    }

    if ($null -eq $Options.Parser) {
        # Without a parser the value is the combined output string.
        return New-PortraitureSuccessResult -Target $Target -Context $context -Value $context.Output -Logger $Options.Logger
    }

    $parseText = switch ($Options.ParseInput) {
        'Combined' { $context.Output }
        'Stderr' { $context.Stderr }
        default { $context.Stdout }
    }

    # Only the parser invocation itself may be classified as a Parse failure.
    try {
        $parsedValue = & $Options.Parser $parseText $context
    } catch {
        return New-PortraitureFailureResult -Target $Target -Context $context -Kind 'Parse' -Message $_.Exception.Message -Cause $_.Exception -Logger $Options.Logger
    }

    New-PortraitureSuccessResult -Target $Target -Context $context -Value $parsedValue -Logger $Options.Logger
}

function New-PortraitureStartInfo {
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Target,

        [Parameter(Mandatory)]
        [pscustomobject] $Options
    )

    $invocation = Resolve-PortraitureInvocation -Target $Target -Options $Options

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $invocation.FileName
    foreach ($argument in $invocation.ArgumentList) {
        [void] $startInfo.ArgumentList.Add($argument)
    }
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.CreateNoWindow = $true

    # Decode child output as UTF-8 (no BOM) regardless of console code page so
    # multi-byte sequences survive intact on every platform.
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $startInfo.StandardOutputEncoding = $utf8
    $startInfo.StandardErrorEncoding = $utf8
    $startInfo.StandardInputEncoding = $utf8

    if (-not [string]::IsNullOrWhiteSpace($Options.WorkingDirectory)) {
        $startInfo.WorkingDirectory = $Options.WorkingDirectory
    }

    if ($null -ne $Options.Environment) {
        foreach ($key in $Options.Environment.Keys) {
            $startInfo.Environment[$key] = [string] $Options.Environment[$key]
        }
    }

    $startInfo
}

function Resolve-PortraitureInvocation {
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Target,

        [Parameter(Mandatory)]
        [pscustomobject] $Options
    )

    if ($Options.UseShell) {
        $commandLine = if ($Target.Kind -eq 'Command') {
            $Target.Command
        } else {
            Join-PortraiturePowerShellCommand (@($Target.Command) + @($Target.Arguments))
        }

        return [pscustomobject]@{
            FileName = Get-PortraiturePowerShellExecutable
            ArgumentList = @('-NoProfile', '-NonInteractive', '-Command', $commandLine)
        }
    }

    [pscustomobject]@{
        FileName = $Target.Command
        ArgumentList = @($Target.Arguments)
    }
}

function Resolve-PortraitureConfig {
    param([object] $Portraiture)

    if ($null -eq $Portraiture) {
        return New-Portraiture
    }

    $Portraiture
}

function Resolve-PortraitureOptions {
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Config,

        [Parameter(Mandatory)]
        [ValidateSet('Command', 'Process', 'Script')]
        [string] $Kind,

        [Parameter(Mandatory)]
        [hashtable] $BoundParameters
    )

    if ($BoundParameters.ContainsKey('AllowNonzeroExit') -and
        $BoundParameters['AllowNonzeroExit'].IsPresent -and
        $BoundParameters.ContainsKey('FailOnNonzeroExit')) {
        throw 'Use either -AllowNonzeroExit or -FailOnNonzeroExit, not both.'
    }

    $failOnNonzero = $Config.FailOnNonzeroExit
    if ($BoundParameters.ContainsKey('AllowNonzeroExit') -and $BoundParameters['AllowNonzeroExit'].IsPresent) {
        $failOnNonzero = $false
    } elseif ($BoundParameters.ContainsKey('FailOnNonzeroExit')) {
        $failOnNonzero = [bool] $BoundParameters['FailOnNonzeroExit']
    }

    $useShell = if ($null -ne $Config.UseShell) { [bool] $Config.UseShell } else { $Kind -eq 'Command' }
    if ($BoundParameters.ContainsKey('UseShell')) {
        $useShell = [bool] $BoundParameters['UseShell']
    }

    $environmentOverride = if ($BoundParameters.ContainsKey('Environment')) { $BoundParameters['Environment'] } else { $null }

    [pscustomobject]@{
        WorkingDirectory = Resolve-PortraitureOption -Config $Config -BoundParameters $BoundParameters -Name 'WorkingDirectory'
        Environment = Merge-PortraitureEnvironment $Config.Environment $environmentOverride
        FailOnNonzeroExit = $failOnNonzero
        Logger = Resolve-PortraitureOption -Config $Config -BoundParameters $BoundParameters -Name 'Logger'
        ParseInput = Resolve-PortraitureOption -Config $Config -BoundParameters $BoundParameters -Name 'ParseInput' -Default 'Stdout'
        Parser = if ($BoundParameters.ContainsKey('Parser')) { $BoundParameters['Parser'] } else { $null }
        UseShell = $useShell
        StderrPolicy = Resolve-PortraitureOption -Config $Config -BoundParameters $BoundParameters -Name 'StderrPolicy' -Default 'Capture'
        StandardInput = Resolve-PortraitureOption -Config $Config -BoundParameters $BoundParameters -Name 'StandardInput'
        TimeoutMilliseconds = Resolve-PortraitureOption -Config $Config -BoundParameters $BoundParameters -Name 'TimeoutMilliseconds'
    }
}

function Resolve-PortraitureOption {
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Config,

        [Parameter(Mandatory)]
        [hashtable] $BoundParameters,

        [Parameter(Mandatory)]
        [string] $Name,

        [object] $Default = $null
    )

    if ($BoundParameters.ContainsKey($Name)) {
        return $BoundParameters[$Name]
    }

    if ($Config.PSObject.Properties[$Name] -and $null -ne $Config.$Name) {
        return $Config.$Name
    }

    $Default
}

function Resolve-PortraitureInterpreter {
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Config,

        [Parameter(Mandatory)]
        [string] $Path,

        [object] $CallInterpreter
    )

    if ($null -ne $CallInterpreter) {
        return ConvertTo-PortraitureInterpreter $CallInterpreter
    }

    if ($null -ne $Config.Interpreter) {
        return ConvertTo-PortraitureInterpreter $Config.Interpreter
    }

    $extension = [System.IO.Path]::GetExtension($Path)
    if ([string]::IsNullOrWhiteSpace($extension)) {
        return $null
    }

    $withoutDot = $extension.TrimStart('.')
    if ($Config.Interpreters.ContainsKey($extension)) {
        return ConvertTo-PortraitureInterpreter $Config.Interpreters[$extension]
    }
    if ($Config.Interpreters.ContainsKey($withoutDot)) {
        return ConvertTo-PortraitureInterpreter $Config.Interpreters[$withoutDot]
    }

    $null
}

function New-PortraitureTarget {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Command', 'Process', 'Script')]
        [string] $Kind,

        [Parameter(Mandatory)]
        [string] $Command,

        [string[]] $ArgumentList = @(),
        [string] $Script,
        [object] $Interpreter
    )

    $target = [pscustomobject]@{
        Kind = $Kind
        Command = $Command
        Arguments = @($ArgumentList)
        Script = $Script
        Interpreter = $Interpreter
    }
    $target.PSTypeNames.Insert(0, 'Portraiture.Target')
    $target
}

function New-PortraitureContext {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Stdout,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Stderr,

        [object] $ExitCode,

        [Parameter(Mandatory)]
        [long] $DurationMs
    )

    $chunks = @()
    if ($Stdout.Length -gt 0) {
        $chunks += New-PortraitureChunk -Stream 'Stdout' -Text $Stdout
    }
    if ($Stderr.Length -gt 0) {
        $chunks += New-PortraitureChunk -Stream 'Stderr' -Text $Stderr
    }

    [pscustomobject]@{
        Stdout = $Stdout
        Stderr = $Stderr
        Output = $Stdout + $Stderr
        Chunks = @($chunks)
        ExitCode = $ExitCode
        Signal = $null
        DurationMs = $DurationMs
    }
}

function New-PortraitureChunk {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Stdout', 'Stderr')]
        [string] $Stream,

        [Parameter(Mandatory)]
        [string] $Text
    )

    $chunk = [pscustomobject]@{
        Stream = $Stream
        Text = $Text
    }
    $chunk.PSTypeNames.Insert(0, 'Portraiture.Chunk')
    $chunk
}

function New-PortraitureSuccessResult {
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Target,

        [Parameter(Mandatory)]
        [pscustomobject] $Context,

        [object] $Value,
        [scriptblock] $Logger
    )

    $result = New-PortraitureBaseResult -Target $Target -Context $Context
    $result.Ok = $true
    $result.Value = $Value
    $result.Error = $null
    $result.PSTypeNames.Insert(0, 'Portraiture.Result')
    Invoke-PortraitureLogger $Logger (New-PortraitureFinishEvent -Target $Target -Result $result)
    $result
}

function New-PortraitureFailureResult {
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Target,

        [Parameter(Mandatory)]
        [pscustomobject] $Context,

        [Parameter(Mandatory)]
        [string] $Kind,

        [Parameter(Mandatory)]
        [string] $Message,

        [object] $Cause,
        [scriptblock] $Logger
    )

    $failure = [pscustomobject]@{
        Kind = $Kind
        Message = $Message
        Cause = $Cause
    }
    $failure.PSTypeNames.Insert(0, 'Portraiture.Failure')

    $result = New-PortraitureBaseResult -Target $Target -Context $Context
    $result.Ok = $false
    $result.Value = $null
    $result.Error = $failure
    $result.PSTypeNames.Insert(0, 'Portraiture.Result')
    Invoke-PortraitureLogger $Logger (New-PortraitureFinishEvent -Target $Target -Result $result)
    $result
}

function New-PortraitureBaseResult {
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Target,

        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    [pscustomobject]@{
        Ok = $false
        Value = $null
        Error = $null
        Stdout = $Context.Stdout
        Stderr = $Context.Stderr
        Output = $Context.Output
        Chunks = $Context.Chunks
        ExitCode = $Context.ExitCode
        Signal = $Context.Signal
        DurationMs = $Context.DurationMs
        Target = $Target
    }
}

function New-PortraitureFinishEvent {
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Target,

        [Parameter(Mandatory)]
        [pscustomobject] $Result
    )

    [pscustomobject]@{
        Type = 'Finish'
        Target = $Target
        Ok = $Result.Ok
        DurationMs = $Result.DurationMs
        ExitCode = $Result.ExitCode
        Signal = $Result.Signal
    }
}

function Stop-PortraitureProcess {
    param([Parameter(Mandatory)] [System.Diagnostics.Process] $Process)

    try {
        $Process.Kill($true)
    } catch {
        try {
            $Process.Kill()
        } catch {
        }
    }

    try {
        $Process.WaitForExit()
    } catch {
    }
}

function Invoke-PortraitureLogger {
    param(
        [scriptblock] $Logger,
        [Parameter(Mandatory)]
        [pscustomobject] $Event
    )

    if ($null -eq $Logger) {
        return
    }

    try {
        & $Logger $Event
    } catch {
    }
}

function ConvertTo-PortraitureInterpreter {
    param([object] $Interpreter)

    if ($null -eq $Interpreter) {
        return $null
    }

    if ($Interpreter -is [string]) {
        return New-PortraitureInterpreter -Command $Interpreter
    }

    $command = $null
    $arguments = @()

    if ($Interpreter -is [hashtable]) {
        $command = $Interpreter['Command']
        if ($Interpreter.ContainsKey('Arguments')) {
            $arguments = @($Interpreter['Arguments'])
        } elseif ($Interpreter.ContainsKey('Args')) {
            $arguments = @($Interpreter['Args'])
        } elseif ($Interpreter.ContainsKey('ArgumentList')) {
            $arguments = @($Interpreter['ArgumentList'])
        }
    } else {
        if ($Interpreter.PSObject.Properties['Command']) {
            $command = $Interpreter.Command
        }
        if ($Interpreter.PSObject.Properties['Arguments']) {
            $arguments = @($Interpreter.Arguments)
        } elseif ($Interpreter.PSObject.Properties['Args']) {
            $arguments = @($Interpreter.Args)
        } elseif ($Interpreter.PSObject.Properties['ArgumentList']) {
            $arguments = @($Interpreter.ArgumentList)
        }
    }

    if ([string]::IsNullOrWhiteSpace($command)) {
        throw 'Interpreter must include a Command.'
    }

    New-PortraitureInterpreter -Command $command -ArgumentList @($arguments)
}

function ConvertTo-PortraitureInterpreterMap {
    param([hashtable] $Interpreters)

    $map = @{}
    if ($null -eq $Interpreters) {
        return $map
    }

    foreach ($key in $Interpreters.Keys) {
        $map[[string] $key] = ConvertTo-PortraitureInterpreter $Interpreters[$key]
    }

    $map
}

function Copy-PortraitureHashtable {
    param([hashtable] $Value)

    if ($null -eq $Value) {
        return $null
    }

    $copy = @{}
    foreach ($key in $Value.Keys) {
        $copy[[string] $key] = $Value[$key]
    }
    $copy
}

function Merge-PortraitureEnvironment {
    param(
        [hashtable] $Defaults,
        [hashtable] $Overrides
    )

    if ($null -eq $Defaults -and $null -eq $Overrides) {
        return $null
    }

    $merged = @{}
    if ($null -ne $Defaults) {
        foreach ($key in $Defaults.Keys) {
            $merged[[string] $key] = [string] $Defaults[$key]
        }
    }
    if ($null -ne $Overrides) {
        foreach ($key in $Overrides.Keys) {
            $merged[[string] $key] = [string] $Overrides[$key]
        }
    }
    $merged
}

function Get-PortraiturePowerShellExecutable {
    try {
        $path = (Get-Process -Id $PID).Path
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            return $path
        }
    } catch {
    }

    if ($PSVersionTable.PSEdition -eq 'Core') {
        'pwsh'
    } else {
        'powershell.exe'
    }
}

function Join-PortraiturePowerShellCommand {
    param([string[]] $Parts)

    ($Parts | ForEach-Object { ConvertTo-PortraiturePowerShellLiteral $_ }) -join ' '
}

function ConvertTo-PortraiturePowerShellLiteral {
    param([string] $Value)

    "'" + ($Value -replace "'", "''") + "'"
}

Export-ModuleMember -Function @(
    'New-Portraiture',
    'New-PortraitureInterpreter',
    'Invoke-PortraitureCommand',
    'Invoke-PortraitureProcess',
    'Invoke-PortraitureScript'
)
