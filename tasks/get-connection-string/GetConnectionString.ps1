[CmdletBinding()]
param()

Trace-VstsEnteringInvocation $MyInvocation
try {
    # Load shared functions and other dependencies
    ("PipelineVariables.ps1", "ConnectionStringFunctions.ps1") `
        | %{ Join-Path -Path $PSScriptRoot $_ } | Import-Module
    # Get input parameters and credentials

    Write-Verbose "Creating Connection string to: $($authInfo.EnvironmentUrl)..."
    $outputVariableName = Get-VSTSInput -Name "OutputVariableName" -Require
    $connectingString = Get-ConnectionStringFromActiveServiceConnection

    Write-VstsSetVariable -Name $outputVariableName -Value $connectingString -Secret
    #Write-Host "##vso[task.setvariable variable=$($outputVariableName);issecret=true]$($connectingString)"
} finally {
    Trace-VstsLeavingInvocation $MyInvocation
}