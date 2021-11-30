[CmdletBinding()]
param(
    [ValidateNotNull()]
    [Parameter()]
    [hashtable]$ModuleParameters = @{ })

if ($host.Name -ne 'ConsoleHost') {
    Write-Warning "VstsTaskSdk is designed for use with powershell.exe (ConsoleHost). Output may be different when used with other hosts."
}

# Private module variables.
[bool]$script:nonInteractive = "$($ModuleParameters['NonInteractive'])" -eq 'true'
Write-Verbose "NonInteractive: $script:nonInteractive"

# VstsTaskSdk.dll contains the TerminationException and NativeMethods for handle long path
# We used to do inline C# in this powershell module
# However when csc compile the inline C#, it will hit process env block size limit since it's not use unicode to encode env
# To solve the env block size problem, we choose to put all inline C# into an assembly VstsTaskSdk.dll, signing it, package with the PS modules.
Write-Verbose "Loading compiled helper $PSScriptRoot\VstsTaskSdk.dll."
Add-Type -LiteralPath $PSScriptRoot\VstsTaskSdk.dll

# Import/export functions.
. "$PSScriptRoot\FindFunctions.ps1"
. "$PSScriptRoot\InputFunctions.ps1"
. "$PSScriptRoot\LegacyFindFunctions.ps1"
. "$PSScriptRoot\LocalizationFunctions.ps1"
. "$PSScriptRoot\LoggingCommandFunctions.ps1"
. "$PSScriptRoot\LongPathFunctions.ps1"
. "$PSScriptRoot\ServerOMFunctions.ps1"
. "$PSScriptRoot\ToolFunctions.ps1"
. "$PSScriptRoot\TraceFunctions.ps1"
. "$PSScriptRoot\OutFunctions.ps1" # Load the out functions after all of the other functions are loaded.
Export-ModuleMember -Function @(
        # Find functions.
        'Find-Match'
        'New-FindOptions'
        'New-MatchOptions'
        'Select-Match'
        # Input functions.
        'Get-Endpoint'
        'Get-SecureFileTicket'
        'Get-SecureFileName'
        'Get-Input'
        'Get-TaskVariable'
        'Get-TaskVariableInfo'
        'Set-TaskVariable'
        # Legacy find functions.
        'Find-Files'
        # Localization functions.
        'Get-LocString'
        'Import-LocStrings'
        # Logging command functions.
        'Write-AddAttachment'
        'Write-AddBuildTag'
        'Write-AssociateArtifact'
        'Write-LogDetail'
        'Write-PrependPath'
        'Write-SetEndpoint'
        'Write-SetProgress'
        'Write-SetResult'
        'Write-SetSecret'
        'Write-SetVariable'
        'Write-TaskDebug'
        'Write-TaskError'
        'Write-TaskVerbose'
        'Write-TaskWarning'
        'Write-UpdateBuildNumber'
        'Write-UpdateReleaseName'
        'Write-UploadArtifact'
        'Write-UploadBuildLog'
        'Write-UploadFile'
        'Write-UploadSummary'
        # Out functions.
        'Out-Default'
        # Server OM functions.
        'Get-AssemblyReference'
        'Get-TfsClientCredentials'
        'Get-TfsService'
        'Get-VssCredentials'
        'Get-VssHttpClient'
        # Tool functions.
        'Assert-Agent'
        'Assert-Path'
        'Invoke-Tool'
        # Trace functions.
        'Trace-EnteringInvocation'
        'Trace-LeavingInvocation'
        'Trace-Path'
        # Proxy functions
        'Get-WebProxy'
        # Client cert functions
        'Get-ClientCertificate'
    )

# Override Out-Default globally.
$null = New-Item -Force -Path "function:\global:Out-Default" -Value (Get-Command -CommandType Function -Name Out-Default -ListImported)
New-Alias -Name Out-Default -Value "global:Out-Default" -Scope global

# Perform some initialization in a script block to enable merging the pipelines.
$scriptText = @"
# Load the SDK resource strings.
Import-LocStrings "$PSScriptRoot\lib.json"

# Load the module that contains ConvertTo-SecureString.
if (!(Get-Module -Name Microsoft.PowerShell.Security)) {
    Write-Verbose "Importing the module 'Microsoft.PowerShell.Security'."
    Import-Module -Name Microsoft.PowerShell.Security 2>&1 |
        ForEach-Object {
            if (`$_ -is [System.Management.Automation.ErrorRecord]) {
                Write-Verbose `$_.Exception.Message
            } else {
                ,`$_
            }
        }
}
"@
. ([scriptblock]::Create($scriptText)) 2>&1 3>&1 4>&1 5>&1 | Out-Default

# Create Invoke-VstsTaskScript in a special way so it is not bound to the module.
# Otherwise calling the task script block would run within the module context.
#
# An alternative way to solve the problem is to close the script block (i.e. closure).
# However, that introduces a different problem. Closed script blocks are created within
# a dynamic module. Each module gets it's own session state separate from the global
# session state. When running in a regular script context, Import-Module calls import
# the target module into the global session state. When running in a module context,
# Import-Module calls import the target module into the caller module's session state.
#
# The goal of a task may include executing ad-hoc scripts. Therefore, task scripts
# should run in regular script context. The end user specifying an ad-hoc script expects
# the module import rules to be consistent with the default behavior (i.e. imported
# into the global session state).
$null = New-Item -Force -Path "function:\global:Invoke-VstsTaskScript" -Value ([scriptblock]::Create(@'
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock)

    try {
        $global:ErrorActionPreference = 'Stop'

        # Initialize the environment.
        $vstsModule = Get-Module -Name VstsTaskSdk
        Write-Verbose "$($vstsModule.Name) $($vstsModule.Version) commit $($vstsModule.PrivateData.PSData.CommitHash)" 4>&1 | Out-Default
        & $vstsModule Initialize-Inputs 4>&1 | Out-Default

        # Remove the local variable before calling the user's script.
        Remove-Variable -Name vstsModule

        # Call the user's script.
        $ScriptBlock |
            ForEach-Object {
                # Remove the scriptblock variable before calling it.
                Remove-Variable -Name ScriptBlock
                & $_ 2>&1 3>&1 4>&1 5>&1 | Out-Default
            }
    } catch [VstsTaskSdk.TerminationException] {
        # Special internal exception type to control the flow. Not currently intended
        # for public usage and subject to change.
        $global:__vstsNoOverrideVerbose = ''
        Write-Verbose "Task script terminated." 4>&1 | Out-Default
    } catch {
        $global:__vstsNoOverrideVerbose = ''
        Write-Verbose "Caught exception from task script." 4>&1 | Out-Default
        $_ | Out-Default
        Write-Host "##vso[task.complete result=Failed]"
    }
'@))

# SIG # Begin signature block
# MIIjhAYJKoZIhvcNAQcCoIIjdTCCI3ECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBrfjS7OUHRIbk4
# T6FOX9Rueiej3h7VDGwn42fIRH7slqCCDYEwggX/MIID56ADAgECAhMzAAAB32vw
# LpKnSrTQAAAAAAHfMA0GCSqGSIb3DQEBCwUAMH4xCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25p
# bmcgUENBIDIwMTEwHhcNMjAxMjE1MjEzMTQ1WhcNMjExMjAyMjEzMTQ1WjB0MQsw
# CQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9u
# ZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYDVQQDExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIB
# AQC2uxlZEACjqfHkuFyoCwfL25ofI9DZWKt4wEj3JBQ48GPt1UsDv834CcoUUPMn
# s/6CtPoaQ4Thy/kbOOg/zJAnrJeiMQqRe2Lsdb/NSI2gXXX9lad1/yPUDOXo4GNw
# PjXq1JZi+HZV91bUr6ZjzePj1g+bepsqd/HC1XScj0fT3aAxLRykJSzExEBmU9eS
# yuOwUuq+CriudQtWGMdJU650v/KmzfM46Y6lo/MCnnpvz3zEL7PMdUdwqj/nYhGG
# 3UVILxX7tAdMbz7LN+6WOIpT1A41rwaoOVnv+8Ua94HwhjZmu1S73yeV7RZZNxoh
# EegJi9YYssXa7UZUUkCCA+KnAgMBAAGjggF+MIIBejAfBgNVHSUEGDAWBgorBgEE
# AYI3TAgBBggrBgEFBQcDAzAdBgNVHQ4EFgQUOPbML8IdkNGtCfMmVPtvI6VZ8+Mw
# UAYDVR0RBEkwR6RFMEMxKTAnBgNVBAsTIE1pY3Jvc29mdCBPcGVyYXRpb25zIFB1
# ZXJ0byBSaWNvMRYwFAYDVQQFEw0yMzAwMTIrNDYzMDA5MB8GA1UdIwQYMBaAFEhu
# ZOVQBdOCqhc3NyK1bajKdQKVMFQGA1UdHwRNMEswSaBHoEWGQ2h0dHA6Ly93d3cu
# bWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY0NvZFNpZ1BDQTIwMTFfMjAxMS0w
# Ny0wOC5jcmwwYQYIKwYBBQUHAQEEVTBTMFEGCCsGAQUFBzAChkVodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY0NvZFNpZ1BDQTIwMTFfMjAx
# MS0wNy0wOC5jcnQwDAYDVR0TAQH/BAIwADANBgkqhkiG9w0BAQsFAAOCAgEAnnqH
# tDyYUFaVAkvAK0eqq6nhoL95SZQu3RnpZ7tdQ89QR3++7A+4hrr7V4xxmkB5BObS
# 0YK+MALE02atjwWgPdpYQ68WdLGroJZHkbZdgERG+7tETFl3aKF4KpoSaGOskZXp
# TPnCaMo2PXoAMVMGpsQEQswimZq3IQ3nRQfBlJ0PoMMcN/+Pks8ZTL1BoPYsJpok
# t6cql59q6CypZYIwgyJ892HpttybHKg1ZtQLUlSXccRMlugPgEcNZJagPEgPYni4
# b11snjRAgf0dyQ0zI9aLXqTxWUU5pCIFiPT0b2wsxzRqCtyGqpkGM8P9GazO8eao
# mVItCYBcJSByBx/pS0cSYwBBHAZxJODUqxSXoSGDvmTfqUJXntnWkL4okok1FiCD
# Z4jpyXOQunb6egIXvkgQ7jb2uO26Ow0m8RwleDvhOMrnHsupiOPbozKroSa6paFt
# VSh89abUSooR8QdZciemmoFhcWkEwFg4spzvYNP4nIs193261WyTaRMZoceGun7G
# CT2Rl653uUj+F+g94c63AhzSq4khdL4HlFIP2ePv29smfUnHtGq6yYFDLnT0q/Y+
# Di3jwloF8EWkkHRtSuXlFUbTmwr/lDDgbpZiKhLS7CBTDj32I0L5i532+uHczw82
# oZDmYmYmIUSMbZOgS65h797rj5JJ6OkeEUJoAVwwggd6MIIFYqADAgECAgphDpDS
# AAAAAAADMA0GCSqGSIb3DQEBCwUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0
# ZSBBdXRob3JpdHkgMjAxMTAeFw0xMTA3MDgyMDU5MDlaFw0yNjA3MDgyMTA5MDla
# MH4xCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdS
# ZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMT
# H01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMTEwggIiMA0GCSqGSIb3DQEB
# AQUAA4ICDwAwggIKAoICAQCr8PpyEBwurdhuqoIQTTS68rZYIZ9CGypr6VpQqrgG
# OBoESbp/wwwe3TdrxhLYC/A4wpkGsMg51QEUMULTiQ15ZId+lGAkbK+eSZzpaF7S
# 35tTsgosw6/ZqSuuegmv15ZZymAaBelmdugyUiYSL+erCFDPs0S3XdjELgN1q2jz
# y23zOlyhFvRGuuA4ZKxuZDV4pqBjDy3TQJP4494HDdVceaVJKecNvqATd76UPe/7
# 4ytaEB9NViiienLgEjq3SV7Y7e1DkYPZe7J7hhvZPrGMXeiJT4Qa8qEvWeSQOy2u
# M1jFtz7+MtOzAz2xsq+SOH7SnYAs9U5WkSE1JcM5bmR/U7qcD60ZI4TL9LoDho33
# X/DQUr+MlIe8wCF0JV8YKLbMJyg4JZg5SjbPfLGSrhwjp6lm7GEfauEoSZ1fiOIl
# XdMhSz5SxLVXPyQD8NF6Wy/VI+NwXQ9RRnez+ADhvKwCgl/bwBWzvRvUVUvnOaEP
# 6SNJvBi4RHxF5MHDcnrgcuck379GmcXvwhxX24ON7E1JMKerjt/sW5+v/N2wZuLB
# l4F77dbtS+dJKacTKKanfWeA5opieF+yL4TXV5xcv3coKPHtbcMojyyPQDdPweGF
# RInECUzF1KVDL3SV9274eCBYLBNdYJWaPk8zhNqwiBfenk70lrC8RqBsmNLg1oiM
# CwIDAQABo4IB7TCCAekwEAYJKwYBBAGCNxUBBAMCAQAwHQYDVR0OBBYEFEhuZOVQ
# BdOCqhc3NyK1bajKdQKVMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMAsGA1Ud
# DwQEAwIBhjAPBgNVHRMBAf8EBTADAQH/MB8GA1UdIwQYMBaAFHItOgIxkEO5FAVO
# 4eqnxzHRI4k0MFoGA1UdHwRTMFEwT6BNoEuGSWh0dHA6Ly9jcmwubWljcm9zb2Z0
# LmNvbS9wa2kvY3JsL3Byb2R1Y3RzL01pY1Jvb0NlckF1dDIwMTFfMjAxMV8wM18y
# Mi5jcmwwXgYIKwYBBQUHAQEEUjBQME4GCCsGAQUFBzAChkJodHRwOi8vd3d3Lm1p
# Y3Jvc29mdC5jb20vcGtpL2NlcnRzL01pY1Jvb0NlckF1dDIwMTFfMjAxMV8wM18y
# Mi5jcnQwgZ8GA1UdIASBlzCBlDCBkQYJKwYBBAGCNy4DMIGDMD8GCCsGAQUFBwIB
# FjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2RvY3MvcHJpbWFyeWNw
# cy5odG0wQAYIKwYBBQUHAgIwNB4yIB0ATABlAGcAYQBsAF8AcABvAGwAaQBjAHkA
# XwBzAHQAYQB0AGUAbQBlAG4AdAAuIB0wDQYJKoZIhvcNAQELBQADggIBAGfyhqWY
# 4FR5Gi7T2HRnIpsLlhHhY5KZQpZ90nkMkMFlXy4sPvjDctFtg/6+P+gKyju/R6mj
# 82nbY78iNaWXXWWEkH2LRlBV2AySfNIaSxzzPEKLUtCw/WvjPgcuKZvmPRul1LUd
# d5Q54ulkyUQ9eHoj8xN9ppB0g430yyYCRirCihC7pKkFDJvtaPpoLpWgKj8qa1hJ
# Yx8JaW5amJbkg/TAj/NGK978O9C9Ne9uJa7lryft0N3zDq+ZKJeYTQ49C/IIidYf
# wzIY4vDFLc5bnrRJOQrGCsLGra7lstnbFYhRRVg4MnEnGn+x9Cf43iw6IGmYslmJ
# aG5vp7d0w0AFBqYBKig+gj8TTWYLwLNN9eGPfxxvFX1Fp3blQCplo8NdUmKGwx1j
# NpeG39rz+PIWoZon4c2ll9DuXWNB41sHnIc+BncG0QaxdR8UvmFhtfDcxhsEvt9B
# xw4o7t5lL+yX9qFcltgA1qFGvVnzl6UJS0gQmYAf0AApxbGbpT9Fdx41xtKiop96
# eiL6SJUfq/tHI4D1nvi/a7dLl+LrdXga7Oo3mXkYS//WsyNodeav+vyL6wuA6mk7
# r/ww7QRMjt/fdW1jkT3RnVZOT7+AVyKheBEyIXrvQQqxP/uozKRdwaGIm1dxVk5I
# RcBCyZt2WwqASGv9eZ/BvW1taslScxMNelDNMYIVWTCCFVUCAQEwgZUwfjELMAkG
# A1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQx
# HjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEoMCYGA1UEAxMfTWljcm9z
# b2Z0IENvZGUgU2lnbmluZyBQQ0EgMjAxMQITMwAAAd9r8C6Sp0q00AAAAAAB3zAN
# BglghkgBZQMEAgEFAKCBoDAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgor
# BgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgHao0ok8I
# NsL7yyAqKZpzxCZI3YVO8GB8AC0q1heKOhYwNAYKKwYBBAGCNwIBDDEmMCSgEoAQ
# AFQAZQBzAHQAUwBpAGcAbqEOgAxodHRwOi8vdGVzdCAwDQYJKoZIhvcNAQEBBQAE
# ggEAXsE5Jz2YSfAPKjcowh1SNPV9jttZg9VBQI5obCVkjTGwHildJxogh/MFwPU3
# Iy7X9uu5B5eeRIcfFzULyfihFvkW+V0rtmO29ieAfqMya0A10uZqwG1y4ZV2AyVd
# nmVzVinQenX5p4/pDUsrMnRYQI4bM9tsTksSVVQmohZg/Nn2mOrBYIV+lqG47jx8
# 2ahIjIhjd0+IDUUMq3MWKoEAm86S1e2iOHrmot+LmvG8SB2F2q0XxaOofi0TQ0UD
# Fs9GgCa7Cb1/+9ZAUA9A5q/MFdrrA1/bc77IE98CcpRlgY2W4BR6y+xGVqJvt+mo
# 10z9Ez1IdjrawR96g5HNdWSTyaGCEvEwghLtBgorBgEEAYI3AwMBMYIS3TCCEtkG
# CSqGSIb3DQEHAqCCEsowghLGAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFVBgsqhkiG
# 9w0BCRABBKCCAUQEggFAMIIBPAIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCAkhBvXp+Xt9yi2KlUL+ATmkJFPQJ0HKjn/fLM7y57RcwIGYUTFHQzcGBMy
# MDIxMDkyNDAwMDMxMC4zNTNaMASAAgH0oIHUpIHRMIHOMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSkwJwYDVQQLEyBNaWNyb3NvZnQgT3BlcmF0
# aW9ucyBQdWVydG8gUmljbzEmMCQGA1UECxMdVGhhbGVzIFRTUyBFU046ODk3QS1F
# MzU2LTE3MDExJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2Wg
# gg5EMIIE9TCCA92gAwIBAgITMwAAAWAHIPCSSNq+6wAAAAABYDANBgkqhkiG9w0B
# AQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYD
# VQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAeFw0yMTAxMTQxOTAy
# MjBaFw0yMjA0MTExOTAyMjBaMIHOMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2Fz
# aGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMSkwJwYDVQQLEyBNaWNyb3NvZnQgT3BlcmF0aW9ucyBQdWVydG8g
# UmljbzEmMCQGA1UECxMdVGhhbGVzIFRTUyBFU046ODk3QS1FMzU2LTE3MDExJTAj
# BgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggEiMA0GCSqGSIb3
# DQEBAQUAA4IBDwAwggEKAoIBAQC0MYAc0PLGzPFSMz4JjfU1pFrNpPEtQmVMjefE
# i8y1t9efK2WfzuJevBm+EpBP4gVEpOMlXrASjlaJ2yy95wMCF5rGIZ+QUdEVzyPV
# y4s81arJVIBz80z0bTLWbvo7coAqYeTH6rgYmv0qdB44+5RA6zR0fwv9f8QmmckK
# YCEe5QESSGkVYecvlqm6pm1LBSKBeVB8MMyRSaTl8WLQNLlrq2iqXQlMwM4esJCm
# YDJEa1z9xP8OXLOFO3GImI2URpZtxq/ryYJMk7CltzgYk7ZGlv3o7aVvkuqbvzXs
# 1xagM8Lkg43iCJjjnhGr5QPTvVaQnsaNc+lQqadBG9/dOLoTAgMBAAGjggEbMIIB
# FzAdBgNVHQ4EFgQUp5se+LeoF+Ca4XUyCXV80Ou+H2MwHwYDVR0jBBgwFoAU1WM6
# XIoxkPNDe3xGG8UzaFqFbVUwVgYDVR0fBE8wTTBLoEmgR4ZFaHR0cDovL2NybC5t
# aWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMvTWljVGltU3RhUENBXzIwMTAt
# MDctMDEuY3JsMFoGCCsGAQUFBwEBBE4wTDBKBggrBgEFBQcwAoY+aHR0cDovL3d3
# dy5taWNyb3NvZnQuY29tL3BraS9jZXJ0cy9NaWNUaW1TdGFQQ0FfMjAxMC0wNy0w
# MS5jcnQwDAYDVR0TAQH/BAIwADATBgNVHSUEDDAKBggrBgEFBQcDCDANBgkqhkiG
# 9w0BAQsFAAOCAQEAFTSYCJs6BaaJUHVPJ2HXF+8kpShD9+faoOUP0hae3uI+XQNV
# fpLL5inWQdY4Y7AbNiJjTiLcjWNrtjcI2uCTcRX/tsvyk3D/BhPex/KIK/XPlW9b
# hxe4LZ3txfL579Am+/SuJm4YuktECIaj3CPHN+lKnj8CjC5t9ifrzvcLiltjSvL/
# WwOYELvdgI+rn+wBgLjWByIdImaJPm3LiaWDyimNZ70thGtYM5hfCf4qz2ODFvL+
# P4GnpCaLH5HOoG6JmuMNYBQxioCob+7ZU9fud7hxkdk0tajGHjcBnxrY4k8UNQZU
# BGYm5OzxXwnvikYU0Uwkbc1p0oNzRBNMtqi51DCCBnEwggRZoAMCAQICCmEJgSoA
# AAAAAAIwDQYJKoZIhvcNAQELBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRl
# IEF1dGhvcml0eSAyMDEwMB4XDTEwMDcwMTIxMzY1NVoXDTI1MDcwMTIxNDY1NVow
# fDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1Jl
# ZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMd
# TWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwggEiMA0GCSqGSIb3DQEBAQUA
# A4IBDwAwggEKAoIBAQCpHQ28dxGKOiDs/BOX9fp/aZRrdFQQ1aUKAIKF++18aEss
# X8XD5WHCdrc+Zitb8BVTJwQxH0EbGpUdzgkTjnxhMFmxMEQP8WCIhFRDDNdNuDgI
# s0Ldk6zWczBXJoKjRQ3Q6vVHgc2/JGAyWGBG8lhHhjKEHnRhZ5FfgVSxz5NMksHE
# pl3RYRNuKMYa+YaAu99h/EbBJx0kZxJyGiGKr0tkiVBisV39dx898Fd1rL2KQk1A
# UdEPnAY+Z3/1ZsADlkR+79BL/W7lmsqxqPJ6Kgox8NpOBpG2iAg16HgcsOmZzTzn
# L0S6p/TcZL2kAcEgCZN4zfy8wMlEXV4WnAEFTyJNAgMBAAGjggHmMIIB4jAQBgkr
# BgEEAYI3FQEEAwIBADAdBgNVHQ4EFgQU1WM6XIoxkPNDe3xGG8UzaFqFbVUwGQYJ
# KwYBBAGCNxQCBAweCgBTAHUAYgBDAEEwCwYDVR0PBAQDAgGGMA8GA1UdEwEB/wQF
# MAMBAf8wHwYDVR0jBBgwFoAU1fZWy4/oolxiaNE9lJBb186aGMQwVgYDVR0fBE8w
# TTBLoEmgR4ZFaHR0cDovL2NybC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVj
# dHMvTWljUm9vQ2VyQXV0XzIwMTAtMDYtMjMuY3JsMFoGCCsGAQUFBwEBBE4wTDBK
# BggrBgEFBQcwAoY+aHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraS9jZXJ0cy9N
# aWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcnQwgaAGA1UdIAEB/wSBlTCBkjCBjwYJ
# KwYBBAGCNy4DMIGBMD0GCCsGAQUFBwIBFjFodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vUEtJL2RvY3MvQ1BTL2RlZmF1bHQuaHRtMEAGCCsGAQUFBwICMDQeMiAdAEwA
# ZQBnAGEAbABfAFAAbwBsAGkAYwB5AF8AUwB0AGEAdABlAG0AZQBuAHQALiAdMA0G
# CSqGSIb3DQEBCwUAA4ICAQAH5ohRDeLG4Jg/gXEDPZ2joSFvs+umzPUxvs8F4qn+
# +ldtGTCzwsVmyWrf9efweL3HqJ4l4/m87WtUVwgrUYJEEvu5U4zM9GASinbMQEBB
# m9xcF/9c+V4XNZgkVkt070IQyK+/f8Z/8jd9Wj8c8pl5SpFSAK84Dxf1L3mBZdmp
# tWvkx872ynoAb0swRCQiPM/tA6WWj1kpvLb9BOFwnzJKJ/1Vry/+tuWOM7tiX5rb
# V0Dp8c6ZZpCM/2pif93FSguRJuI57BlKcWOdeyFtw5yjojz6f32WapB4pm3S4Zz5
# Hfw42JT0xqUKloakvZ4argRCg7i1gJsiOCC1JeVk7Pf0v35jWSUPei45V3aicaoG
# ig+JFrphpxHLmtgOR5qAxdDNp9DvfYPw4TtxCd9ddJgiCGHasFAeb73x4QDf5zEH
# pJM692VHeOj4qEir995yfmFrb3epgcunCaw5u+zGy9iCtHLNHfS4hQEegPsbiSpU
# ObJb2sgNVZl6h3M7COaYLeqN4DMuEin1wC9UJyH3yKxO2ii4sanblrKnQqLJzxlB
# TeCG+SqaoxFmMNO7dDJL32N79ZmKLxvHIa9Zta7cRDyXUHHXodLFVeNp3lfB0d4w
# wP3M5k37Db9dT+mdHhk4L7zPWAUu7w2gUDXa7wknHNWzfjUeCLraNtvTX4/edIhJ
# EqGCAtIwggI7AgEBMIH8oYHUpIHRMIHOMQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMSkwJwYDVQQLEyBNaWNyb3NvZnQgT3BlcmF0aW9ucyBQdWVy
# dG8gUmljbzEmMCQGA1UECxMdVGhhbGVzIFRTUyBFU046ODk3QS1FMzU2LTE3MDEx
# JTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WiIwoBATAHBgUr
# DgMCGgMVAPsyknR1i0TcyJcqh1cV2YCp2dCioIGDMIGApH4wfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTAwDQYJKoZIhvcNAQEFBQACBQDk9yxxMCIYDzIwMjEw
# OTIzMjA0MDE3WhgPMjAyMTA5MjQyMDQwMTdaMHcwPQYKKwYBBAGEWQoEATEvMC0w
# CgIFAOT3LHECAQAwCgIBAAICIw4CAf8wBwIBAAICET0wCgIFAOT4ffECAQAwNgYK
# KwYBBAGEWQoEAjEoMCYwDAYKKwYBBAGEWQoDAqAKMAgCAQACAwehIKEKMAgCAQAC
# AwGGoDANBgkqhkiG9w0BAQUFAAOBgQAH/VoZHwLUHZG4xS6Yr7hFp+lXjwFTJn07
# iKVxuuBlhojlq6//r1LzXdHKfQyOb5HSq64DzgRBvxNTiqlj+lerbQVNuZOjmirY
# dJCw5PHhc+9O37/cH3ALXcLeSdKj7YrqYtAUeTruxirJfMRObkOz0lYh+EvBtMVE
# FC97Qcy+/zGCAw0wggMJAgEBMIGTMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAy
# MDEwAhMzAAABYAcg8JJI2r7rAAAAAAFgMA0GCWCGSAFlAwQCAQUAoIIBSjAaBgkq
# hkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQwLwYJKoZIhvcNAQkEMSIEIOWGvqJ0xkKZ
# Oqoe0wiJ5jNgx8cq1WU9nSFI8dIUh4CmMIH6BgsqhkiG9w0BCRACLzGB6jCB5zCB
# 5DCBvQQgAhKjvaNzLpdbRaevHuoryn6V0v+PXBcJ4l5I96iwZbkwgZgwgYCkfjB8
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1N
# aWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAWAHIPCSSNq+6wAAAAAB
# YDAiBCAaYH0SuKkio3ufqHhLvaRjEEUIWkD34VwSE7gFLjtASjANBgkqhkiG9w0B
# AQsFAASCAQCwRlZ83gwOBmZwrlRDCmFeE+NkRafM0OzRN6KYP8Uo81qwKA4xVWWT
# mkJljH53eUeLNH1czJJWk4whOCc3qqSrCrtXSdHU8kb2saW/raxZZFSWlHJFxEzT
# cFKNAS9NGwwXQCF2H08fyx3AWhlHZ7q2EitR5g8sxShsqv3PeAZolMkDFHzgUk1g
# avmYpmxPPrPFDgznNCiPooAcS635PYHKGMuph2yglQE+LGK21i0ibzNDLFw69HQn
# aZzqkfKmrKVdtAmvWKdpGD9Z2/tat4rVd3/wI1DzKxMDsakEdg7V0Sho8AxgTQeW
# o+Yd0F4oDmev8H5d4Kgb+SlEKLITfJjx
# SIG # End signature block
