@{
    RootModule = 'Portraiture.psm1'
    ModuleVersion = '0.1.0'
    GUID = 'f5e97f87-3116-4f84-9e95-1f9d21573d49'
    Author = 'Portraiture'
    CompanyName = 'Portraiture'
    Copyright = '(c) Portraiture contributors.'
    Description = 'Run dependency-free environment collection commands and scripts, capturing stdout and stderr as structured results.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'New-Portraiture',
        'New-PortraitureInterpreter',
        'Invoke-PortraitureCommand',
        'Invoke-PortraitureProcess',
        'Invoke-PortraitureScript'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('portraiture', 'capture', 'environment', 'diagnostics')
            ProjectUri = 'https://github.com/umeboshi/Portraiture'
        }
    }
}
