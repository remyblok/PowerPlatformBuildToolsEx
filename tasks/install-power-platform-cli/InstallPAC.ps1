[CmdletBinding()]
param()

Trace-VstsEnteringInvocation $MyInvocation
try {
    $latestVersion = Get-VSTSInput -Name "LatestVersion" -AsBool

    Write-Verbose "Installing Power Platform CLI..."
    $tempPath = Join-Path -Path $env:TEMP "pac.msi"
    Invoke-WebRequest https://aka.ms/PowerAppsCLI -OutFile $tempPath
    msiexec /i $tempPath /quiet /norestart
    Write-VstsPrependPath "$env:localappdata\Microsoft\PowerAppsCLI"

    if (-not $latestVersion) {
        $version = Get-VSTSInput -Name "PowerPlatformCLIVersion"
        Write-Verbose "Installing version $versionPower of Power Platform CLI..."

        . "$env:localappdata\Microsoft\PowerAppsCLI\pac.cmd" install $version
        . "$env:localappdata\Microsoft\PowerAppsCLI\pac.cmd" use $version
    }
} finally {
    Trace-VstsLeavingInvocation $MyInvocation
}