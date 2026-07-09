#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    Import-Module $PSScriptRoot/Portraiture/Portraiture.psd1 -Force

    $pwsh = (Get-Process -Id $PID).Path
    if ([string]::IsNullOrWhiteSpace($pwsh)) {
        $pwsh = 'pwsh'
    }

    function New-TestScript {
        param([string] $Name, [string] $Contents)
        $path = Join-Path $TestDrive "$([Guid]::NewGuid().ToString('N'))-$Name"
        Set-Content -Path $path -Value $Contents -NoNewline
        $path
    }

    function New-TestDirectory {
        $path = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $path | Out-Null
        $path
    }
}

Describe 'Command capture' {
    It 'captures stdout from a command string' {
        $result = Invoke-PortraitureCommand "[Console]::Out.Write('hello')"
        $result.Ok | Should -BeTrue
        $result.Value | Should -Be 'hello'
        $result.Target.Kind | Should -Be 'Command'
    }

    It 'exposes stdout, stderr, combined output, chunks, exit code, and duration' {
        $result = Invoke-PortraitureCommand "[Console]::Out.Write('out'); [Console]::Error.Write('err')"
        $result.Ok | Should -BeTrue
        $result.Stdout | Should -Be 'out'
        $result.Stderr | Should -Be 'err'
        $result.Output | Should -Be 'outerr'
        $result.ExitCode | Should -Be 0
        $result.DurationMs | Should -BeGreaterOrEqual 0
        @($result.Chunks).Count | Should -Be 2
        @($result.Chunks | Where-Object Stream -eq 'Stdout')[0].Text | Should -Be 'out'
        @($result.Chunks | Where-Object Stream -eq 'Stderr')[0].Text | Should -Be 'err'
    }

    It 'uses the combined output string as the value when no parser is given' {
        $result = Invoke-PortraitureCommand "[Console]::Out.Write('out'); [Console]::Error.Write('err')"
        $result.Ok | Should -BeTrue
        $result.Value | Should -Be 'outerr'
    }
}

Describe 'Process capture' {
    It 'passes literal arguments without shell interpretation' {
        $script = New-TestScript 'literal-args.ps1' '[Console]::Out.Write($args[0])'
        $result = Invoke-PortraitureProcess $pwsh @('-NoProfile', '-NonInteractive', '-File', $script, 'hello; echo nope')
        $result.Ok | Should -BeTrue
        $result.Value | Should -Be 'hello; echo nope'
        $result.Target.Kind | Should -Be 'Process'
    }

    It 'records the executable and arguments on the target' {
        $result = Invoke-PortraitureProcess $pwsh @('-NoProfile', '-NonInteractive', '-Command', "[Console]::Out.Write('t')")
        $result.Ok | Should -BeTrue
        $result.Target.Command | Should -Be $pwsh
        @($result.Target.Arguments) | Should -Contain '-NoProfile'
    }
}

Describe 'Script capture' {
    It 'runs a script with an explicit interpreter' {
        $script = New-TestScript 'explicit.portraiture.ps1' '[Console]::Out.Write($args[0])'
        $result = Invoke-PortraitureScript $script @('via-interpreter') -Interpreter @{ Command = $pwsh; Arguments = @('-NoProfile', '-NonInteractive', '-File') }
        $result.Ok | Should -BeTrue
        $result.Value | Should -Be 'via-interpreter'
        $result.Target.Command | Should -Be $pwsh
        $result.Target.Script | Should -Be $script
        $result.Target.Kind | Should -Be 'Script'
    }

    It 'runs a script with a default interpreter configured by extension' {
        $script = New-TestScript 'default.portraiture.ps1' '[Console]::Out.Write($args[0])'
        $portraiture = New-Portraiture -Interpreters @{
            '.ps1' = @{ Command = $pwsh; Arguments = @('-NoProfile', '-NonInteractive', '-File') }
        }
        $result = Invoke-PortraitureScript $script @('from-default') -Portraiture $portraiture
        $result.Ok | Should -BeTrue
        $result.Value | Should -Be 'from-default'
    }

    It 'runs the script path directly when no interpreter is configured' -Skip:([bool] $IsWindows) {
        $script = New-TestScript 'direct.portraiture.sh' "#!/bin/sh`nprintf direct-run"
        chmod +x $script
        $result = Invoke-PortraitureScript $script
        $result.Ok | Should -BeTrue
        $result.Value | Should -Be 'direct-run'
        $result.Target.Command | Should -Be $script
        $result.Target.Script | Should -Be $script
    }

    It 'prefers a per-call interpreter over a configured extension default' {
        $script = New-TestScript 'precedence.portraiture.ps1' '[Console]::Out.Write($args[0])'
        $portraiture = New-Portraiture -Interpreters @{
            '.ps1' = @{ Command = '__portraiture_wrong_interpreter__' }
        }
        $result = Invoke-PortraitureScript $script @('per-call-wins') -Portraiture $portraiture -Interpreter @{ Command = $pwsh; Arguments = @('-NoProfile', '-NonInteractive', '-File') }
        $result.Ok | Should -BeTrue
        $result.Value | Should -Be 'per-call-wins'
        $result.Target.Command | Should -Be $pwsh
    }
}

Describe 'Parsers' {
    It 'parses stdout by default' {
        $result = Invoke-PortraitureCommand "[Console]::Out.Write('{""hostname"":""local""}')" -Parser {
            param($Text, $Context)
            $Text | ConvertFrom-Json
        }
        $result.Ok | Should -BeTrue
        $result.Value.hostname | Should -Be 'local'
    }

    It 'feeds the parser combined output when ParseInput is Combined' {
        $result = Invoke-PortraitureCommand "[Console]::Out.Write('out'); [Console]::Error.Write('err')" -ParseInput Combined -Parser {
            param($Text, $Context)
            $Text
        }
        $result.Ok | Should -BeTrue
        $result.Value | Should -Be 'outerr'
    }

    It 'feeds the parser stdout when ParseInput is explicitly Stdout' {
        $result = Invoke-PortraitureCommand "[Console]::Out.Write('out'); [Console]::Error.Write('err')" -ParseInput Stdout -Parser {
            param($Text, $Context)
            $Text
        }
        $result.Ok | Should -BeTrue
        $result.Value | Should -Be 'out'
    }

    It 'feeds the parser stderr when ParseInput is explicitly Stderr' {
        $result = Invoke-PortraitureCommand "[Console]::Out.Write('out'); [Console]::Error.Write('err')" -ParseInput Stderr -Parser {
            param($Text, $Context)
            $Text
        }
        $result.Ok | Should -BeTrue
        $result.Value | Should -Be 'err'
    }

    It 'returns a Parse failure and preserves output when the parser throws' {
        $result = Invoke-PortraitureCommand "[Console]::Out.Write('not-json')" -Parser {
            param($Text, $Context)
            throw 'nope'
        }
        $result.Ok | Should -BeFalse
        $result.Error.Kind | Should -Be 'Parse'
        $result.Stdout | Should -Be 'not-json'
    }

    It 'does not classify failures outside the parser invocation as Parse' {
        # A throwing logger runs around the parser (chunk events before, Finish
        # after); only the parser call itself may produce a Parse failure.
        $result = Invoke-PortraitureCommand "[Console]::Out.Write('42')" -Parser {
            param($Text, $Context)
            [int] $Text
        } -Logger {
            param($Event)
            throw 'logger exploded'
        }
        $result.Ok | Should -BeTrue
        $result.Value | Should -Be 42
        $result.Error | Should -BeNullOrEmpty
    }
}

Describe 'Failure policies' {
    It 'fails on stderr output under the Fail policy and preserves stderr' {
        $result = Invoke-PortraitureCommand "[Console]::Error.Write('warn')" -StderrPolicy Fail
        $result.Ok | Should -BeFalse
        $result.Error.Kind | Should -Be 'Stderr'
        $result.Stderr | Should -Be 'warn'
    }

    It 'fails on nonzero exit by default and preserves stdout and stderr' {
        $result = Invoke-PortraitureCommand "[Console]::Out.Write('before'); [Console]::Error.Write('bad'); exit 7"
        $result.Ok | Should -BeFalse
        $result.Error.Kind | Should -Be 'Exit'
        $result.ExitCode | Should -Be 7
        $result.Stdout | Should -Be 'before'
        $result.Stderr | Should -Be 'bad'
    }

    It 'collects nonzero exits as data with -AllowNonzeroExit' {
        $result = Invoke-PortraitureCommand "[Console]::Out.Write('data'); exit 7" -AllowNonzeroExit
        $result.Ok | Should -BeTrue
        $result.ExitCode | Should -Be 7
        $result.Value | Should -Be 'data'
    }
}

Describe 'Timeouts and spawn failures' {
    It 'fails with Timeout when the process exceeds the deadline' {
        $result = Invoke-PortraitureCommand 'Start-Sleep -Seconds 5' -TimeoutMilliseconds 50
        $result.Ok | Should -BeFalse
        $result.Error.Kind | Should -Be 'Timeout'
    }

    It 'fails with Spawn when the executable does not exist' {
        $result = Invoke-PortraitureProcess '__portraiture_missing_executable__'
        $result.Ok | Should -BeFalse
        $result.Error.Kind | Should -Be 'Spawn'
    }

    It 'preserves output captured before the timeout' -Skip:([bool] $IsWindows) {
        $result = Invoke-PortraitureProcess '/bin/sh' @('-c', 'printf partial; sleep 30') -TimeoutMilliseconds 500
        $result.Ok | Should -BeFalse
        $result.Error.Kind | Should -Be 'Timeout'
        $result.Stdout | Should -Be 'partial'
    }

    It 'kills the whole process tree so grandchildren cannot hang the capture' -Skip:([bool] $IsWindows) {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-PortraitureProcess '/bin/sh' @('-c', 'echo started; sleep 30 & sleep 30') -TimeoutMilliseconds 500
        $stopwatch.Stop()
        $result.Ok | Should -BeFalse
        $result.Error.Kind | Should -Be 'Timeout'
        $result.Stdout | Should -Match 'started'
        $stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 10
    }

    It 'terminates children that ignore SIGTERM' -Skip:([bool] $IsWindows) {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-PortraitureProcess '/bin/sh' @('-c', 'trap "" TERM; echo tough; sleep 30') -TimeoutMilliseconds 500
        $stopwatch.Stop()
        $result.Ok | Should -BeFalse
        $result.Error.Kind | Should -Be 'Timeout'
        $stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 10
    }

    It 'does not report Timeout for a process that exits before the deadline' {
        $result = Invoke-PortraitureCommand "[Console]::Out.Write('done')" -TimeoutMilliseconds 30000
        $result.Ok | Should -BeTrue
        $result.Value | Should -Be 'done'
        $result.Error | Should -BeNullOrEmpty
    }
}

Describe 'Standard input' {
    It 'passes text stdin to the child' {
        $result = Invoke-PortraitureProcess $pwsh @('-NoProfile', '-NonInteractive', '-Command', '[Console]::Out.Write([Console]::In.ReadToEnd())') -StandardInput 'hello stdin'
        $result.Ok | Should -BeTrue
        $result.Value | Should -Be 'hello stdin'
    }

    It 'does not deadlock when a child never reads a large stdin payload' -Skip:([bool] $IsWindows) {
        $big = 'x' * 1048576
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-PortraitureProcess '/bin/sh' @('-c', 'printf ignored') -StandardInput $big -TimeoutMilliseconds 10000
        $stopwatch.Stop()
        $result.Ok | Should -BeTrue
        $result.Value | Should -Be 'ignored'
        $stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 10
    }

    It 'returns a structured result when the child exits without reading stdin' -Skip:([bool] $IsWindows) {
        $result = Invoke-PortraitureProcess '/bin/sh' @('-c', 'exit 3') -StandardInput ('y' * 1048576) -AllowNonzeroExit -TimeoutMilliseconds 10000
        $result.Ok | Should -BeTrue
        $result.ExitCode | Should -Be 3
        $result.Error | Should -BeNullOrEmpty
    }
}

Describe 'Environment variables' {
    It 'augments the parent environment instead of replacing it' {
        $result = Invoke-PortraitureProcess $pwsh @('-NoProfile', '-NonInteractive', '-Command', '[Console]::Out.Write("$env:PORTRAITURE_TEST_A|$env:PATH")') -Environment @{ PORTRAITURE_TEST_A = 'alpha' }
        $result.Ok | Should -BeTrue
        $parts = $result.Value -split '\|', 2
        $parts[0] | Should -Be 'alpha'
        $parts[1] | Should -Not -BeNullOrEmpty
    }

    It 'keeps parent variables visible alongside supplied ones' {
        $env:PORTRAITURE_TEST_PARENT = 'from-parent'
        try {
            $result = Invoke-PortraitureProcess $pwsh @('-NoProfile', '-NonInteractive', '-Command', '[Console]::Out.Write("$env:PORTRAITURE_TEST_PARENT|$env:PORTRAITURE_TEST_A")') -Environment @{ PORTRAITURE_TEST_A = 'alpha' }
            $result.Ok | Should -BeTrue
            $result.Value | Should -Be 'from-parent|alpha'
        } finally {
            Remove-Item Env:PORTRAITURE_TEST_PARENT -ErrorAction SilentlyContinue
        }
    }

    It 'merges constructor and per-call environments with per-call keys winning' {
        $portraiture = New-Portraiture -Environment @{ PORTRAITURE_TEST_A = 'ctor-a'; PORTRAITURE_TEST_B = 'ctor-b' }
        $result = Invoke-PortraitureProcess $pwsh @('-NoProfile', '-NonInteractive', '-Command', '[Console]::Out.Write("$env:PORTRAITURE_TEST_A|$env:PORTRAITURE_TEST_B")') -Portraiture $portraiture -Environment @{ PORTRAITURE_TEST_B = 'call-b' }
        $result.Ok | Should -BeTrue
        $result.Value | Should -Be 'ctor-a|call-b'
    }
}

Describe 'Multibyte output' {
    It 'does not corrupt multi-byte characters split across read chunks' {
        $expected = [string]::new([char] 0x3042, 100000) + [char]::ConvertFromUtf32(0x1F3A8)
        $result = Invoke-PortraitureProcess $pwsh @('-NoProfile', '-NonInteractive', '-Command', '[Console]::Out.Write([string]::new([char]0x3042, 100000) + [char]::ConvertFromUtf32(0x1F3A8))')
        $result.Ok | Should -BeTrue
        $result.Stdout.Length | Should -Be $expected.Length
        ($result.Stdout -ceq $expected) | Should -BeTrue
    }
}

Describe 'Logging' {
    It 'emits Start, Stdout, Stderr, and Finish events' {
        $events = [System.Collections.Generic.List[string]]::new()
        $result = Invoke-PortraitureCommand "[Console]::Out.Write('out'); [Console]::Error.Write('err')" -Logger {
            param($Event)
            $events.Add($Event.Type)
        }
        $result.Ok | Should -BeTrue
        $events | Should -Contain 'Start'
        $events | Should -Contain 'Stdout'
        $events | Should -Contain 'Stderr'
        $events | Should -Contain 'Finish'
    }

    It 'carries result metadata on the Finish event' {
        $captured = [System.Collections.Generic.List[object]]::new()
        $result = Invoke-PortraitureCommand "[Console]::Out.Write('meta')" -Logger {
            param($Event)
            if ($Event.Type -eq 'Finish') { $captured.Add($Event) }
        }
        $result.Ok | Should -BeTrue
        $captured.Count | Should -Be 1
        $finish = $captured[0]
        $finish.Ok | Should -BeTrue
        $finish.ExitCode | Should -Be 0
        $finish.DurationMs | Should -BeGreaterOrEqual 0
        $finish.Target.Kind | Should -Be 'Command'
    }

    It 'ignores logger exceptions on the success path' {
        $result = Invoke-PortraitureCommand "[Console]::Out.Write('ok')" -Logger {
            param($Event)
            throw 'logger failed'
        }
        $result.Ok | Should -BeTrue
        $result.Value | Should -Be 'ok'
    }

    It 'ignores logger exceptions on failure paths' {
        $result = Invoke-PortraitureCommand "[Console]::Error.Write('boom'); exit 5" -Logger {
            param($Event)
            throw 'logger failed'
        }
        $result.Ok | Should -BeFalse
        $result.Error.Kind | Should -Be 'Exit'
        $result.ExitCode | Should -Be 5
        $result.Stderr | Should -Be 'boom'
    }

    It 'emits Start and a terminal Finish event on spawn failure' {
        $events = [System.Collections.Generic.List[object]]::new()
        $result = Invoke-PortraitureProcess '__portraiture_missing_executable__' -Logger {
            param($Event)
            $events.Add($Event)
        }
        $result.Ok | Should -BeFalse
        $result.Error.Kind | Should -Be 'Spawn'
        @($events | Where-Object Type -eq 'Start').Count | Should -Be 1
        $finish = @($events | Where-Object Type -eq 'Finish')
        $finish.Count | Should -Be 1
        $finish[0].Ok | Should -BeFalse
    }

    It 'ignores logger exceptions on the spawn failure path' {
        $result = Invoke-PortraitureProcess '__portraiture_missing_executable__' -Logger {
            param($Event)
            throw 'logger failed'
        }
        $result.Ok | Should -BeFalse
        $result.Error.Kind | Should -Be 'Spawn'
    }
}

Describe 'Constructor defaults and per-call overrides' {
    It 'uses the constructor working directory by default' {
        $directory = New-TestDirectory
        Set-Content -Path (Join-Path $directory 'marker.txt') -Value 'default' -NoNewline
        $portraiture = New-Portraiture -WorkingDirectory $directory
        $result = Invoke-PortraitureCommand "[Console]::Out.Write((Get-Content marker.txt -Raw))" -Portraiture $portraiture
        $result.Ok | Should -BeTrue
        $result.Value | Should -Be 'default'
    }

    It 'lets a per-call working directory override the constructor default' {
        $defaultDirectory = New-TestDirectory
        $overrideDirectory = New-TestDirectory
        Set-Content -Path (Join-Path $defaultDirectory 'marker.txt') -Value 'default' -NoNewline
        Set-Content -Path (Join-Path $overrideDirectory 'marker.txt') -Value 'override' -NoNewline
        $portraiture = New-Portraiture -WorkingDirectory $defaultDirectory
        $result = Invoke-PortraitureCommand "[Console]::Out.Write((Get-Content marker.txt -Raw))" -Portraiture $portraiture -WorkingDirectory $overrideDirectory
        $result.Ok | Should -BeTrue
        $result.Value | Should -Be 'override'
    }

    It 'applies a constructor stderr policy and allows per-call override' {
        $portraiture = New-Portraiture -StderrPolicy Fail
        $failed = Invoke-PortraitureCommand "[Console]::Error.Write('warn')" -Portraiture $portraiture
        $failed.Ok | Should -BeFalse
        $failed.Error.Kind | Should -Be 'Stderr'

        $collected = Invoke-PortraitureCommand "[Console]::Error.Write('warn')" -Portraiture $portraiture -StderrPolicy Capture
        $collected.Ok | Should -BeTrue
        $collected.Stderr | Should -Be 'warn'
    }

    It 'applies a constructor timeout and allows per-call override' {
        $portraiture = New-Portraiture -TimeoutMilliseconds 200
        $timedOut = Invoke-PortraitureCommand 'Start-Sleep -Seconds 5' -Portraiture $portraiture
        $timedOut.Ok | Should -BeFalse
        $timedOut.Error.Kind | Should -Be 'Timeout'

        $completed = Invoke-PortraitureCommand "[Console]::Out.Write('fast')" -Portraiture $portraiture -TimeoutMilliseconds 30000
        $completed.Ok | Should -BeTrue
        $completed.Value | Should -Be 'fast'
    }

    It 'applies a constructor nonzero-exit policy and allows per-call override' {
        $portraiture = New-Portraiture -AllowNonzeroExit
        $collected = Invoke-PortraitureCommand "[Console]::Out.Write('data'); exit 7" -Portraiture $portraiture
        $collected.Ok | Should -BeTrue
        $collected.ExitCode | Should -Be 7

        $failed = Invoke-PortraitureCommand "[Console]::Out.Write('data'); exit 7" -Portraiture $portraiture -FailOnNonzeroExit $true
        $failed.Ok | Should -BeFalse
        $failed.Error.Kind | Should -Be 'Exit'
    }

    It 'applies a constructor stdin default and allows per-call override' {
        $portraiture = New-Portraiture -StandardInput 'ctor stdin'
        $fromDefault = Invoke-PortraitureProcess $pwsh @('-NoProfile', '-NonInteractive', '-Command', '[Console]::Out.Write([Console]::In.ReadToEnd())') -Portraiture $portraiture
        $fromDefault.Ok | Should -BeTrue
        $fromDefault.Value | Should -Be 'ctor stdin'

        $fromCall = Invoke-PortraitureProcess $pwsh @('-NoProfile', '-NonInteractive', '-Command', '[Console]::Out.Write([Console]::In.ReadToEnd())') -Portraiture $portraiture -StandardInput 'call stdin'
        $fromCall.Ok | Should -BeTrue
        $fromCall.Value | Should -Be 'call stdin'
    }

    It 'applies a constructor ParseInput default and allows per-call override' {
        $portraiture = New-Portraiture -ParseInput Stderr
        $fromDefault = Invoke-PortraitureCommand "[Console]::Out.Write('out'); [Console]::Error.Write('err')" -Portraiture $portraiture -Parser {
            param($Text, $Context)
            $Text
        }
        $fromDefault.Ok | Should -BeTrue
        $fromDefault.Value | Should -Be 'err'

        $fromCall = Invoke-PortraitureCommand "[Console]::Out.Write('out'); [Console]::Error.Write('err')" -Portraiture $portraiture -ParseInput Stdout -Parser {
            param($Text, $Context)
            $Text
        }
        $fromCall.Ok | Should -BeTrue
        $fromCall.Value | Should -Be 'out'
    }

    It 'applies a constructor logger and lets a per-call logger replace it' {
        $ctorEvents = [System.Collections.Generic.List[string]]::new()
        $callEvents = [System.Collections.Generic.List[string]]::new()
        $portraiture = New-Portraiture -Logger {
            param($Event)
            $ctorEvents.Add($Event.Type)
        }

        $first = Invoke-PortraitureCommand "[Console]::Out.Write('one')" -Portraiture $portraiture
        $first.Ok | Should -BeTrue
        $ctorEvents | Should -Contain 'Finish'

        $ctorEvents.Clear()
        $second = Invoke-PortraitureCommand "[Console]::Out.Write('two')" -Portraiture $portraiture -Logger {
            param($Event)
            $callEvents.Add($Event.Type)
        }
        $second.Ok | Should -BeTrue
        $callEvents | Should -Contain 'Finish'
        $ctorEvents.Count | Should -Be 0
    }
}
