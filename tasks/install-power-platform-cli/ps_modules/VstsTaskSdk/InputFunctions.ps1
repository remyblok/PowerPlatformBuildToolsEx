# Hash table of known variable info. The formatted env var name is the lookup key.
#
# The purpose of this hash table is to keep track of known variables. The hash table
# needs to be maintained for multiple reasons:
#  1) to distinguish between env vars and job vars
#  2) to distinguish between secret vars and public
#  3) to know the real variable name and not just the formatted env var name.
$script:knownVariables = @{ }
$script:vault = @{ }

<#
.SYNOPSIS
Gets an endpoint.

.DESCRIPTION
Gets an endpoint object for the specified endpoint name. The endpoint is returned as an object with three properties: Auth, Data, and Url.

The Data property requires a 1.97 agent or higher.

.PARAMETER Require
Writes an error to the error pipeline if the endpoint is not found.
#>
function Get-Endpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [switch]$Require)

    $originalErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Stop'

        # Get the URL.
        $description = Get-LocString -Key PSLIB_EndpointUrl0 -ArgumentList $Name
        $key = "ENDPOINT_URL_$Name"
        $url = Get-VaultValue -Description $description -Key $key -Require:$Require

        # Get the auth object.
        $description = Get-LocString -Key PSLIB_EndpointAuth0 -ArgumentList $Name
        $key = "ENDPOINT_AUTH_$Name"
        if ($auth = (Get-VaultValue -Description $description -Key $key -Require:$Require)) {
            $auth = ConvertFrom-Json -InputObject $auth
        }

        # Get the data.
        $description = "'$Name' service endpoint data"
        $key = "ENDPOINT_DATA_$Name"
        if ($data = (Get-VaultValue -Description $description -Key $key)) {
            $data = ConvertFrom-Json -InputObject $data
        }

        # Return the endpoint.
        if ($url -or $auth -or $data) {
            New-Object -TypeName psobject -Property @{
                Url = $url
                Auth = $auth
                Data = $data
            }
        }
    } catch {
        $ErrorActionPreference = $originalErrorActionPreference
        Write-Error $_
    }
}

<#
.SYNOPSIS
Gets a secure file ticket.

.DESCRIPTION
Gets the secure file ticket that can be used to download the secure file contents.

.PARAMETER Id
Secure file id.

.PARAMETER Require
Writes an error to the error pipeline if the ticket is not found.
#>
function Get-SecureFileTicket {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,
        [switch]$Require)

    $originalErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Stop'

        $description = Get-LocString -Key PSLIB_Input0 -ArgumentList $Id
        $key = "SECUREFILE_TICKET_$Id"
        
        Get-VaultValue -Description $description -Key $key -Require:$Require
    } catch {
        $ErrorActionPreference = $originalErrorActionPreference
        Write-Error $_
    }
}

<#
.SYNOPSIS
Gets a secure file name.

.DESCRIPTION
Gets the name for a secure file.

.PARAMETER Id
Secure file id.

.PARAMETER Require
Writes an error to the error pipeline if the ticket is not found.
#>
function Get-SecureFileName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,
        [switch]$Require)

    $originalErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Stop'

        $description = Get-LocString -Key PSLIB_Input0 -ArgumentList $Id
        $key = "SECUREFILE_NAME_$Id"
        
        Get-VaultValue -Description $description -Key $key -Require:$Require
    } catch {
        $ErrorActionPreference = $originalErrorActionPreference
        Write-Error $_
    }
}

<#
.SYNOPSIS
Gets an input.

.DESCRIPTION
Gets the value for the specified input name.

.PARAMETER AsBool
Returns the value as a bool. Returns true if the value converted to a string is "1" or "true" (case insensitive); otherwise false.

.PARAMETER AsInt
Returns the value as an int. Returns the value converted to an int. Returns 0 if the conversion fails.

.PARAMETER Default
Default value to use if the input is null or empty.

.PARAMETER Require
Writes an error to the error pipeline if the input is null or empty.
#>
function Get-Input {
    [CmdletBinding(DefaultParameterSetName = 'Require')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(ParameterSetName = 'Default')]
        $Default,
        [Parameter(ParameterSetName = 'Require')]
        [switch]$Require,
        [switch]$AsBool,
        [switch]$AsInt)

    # Get the input from the vault. Splat the bound parameters hashtable. Splatting is required
    # in order to concisely invoke the correct parameter set.
    $null = $PSBoundParameters.Remove('Name')
    $description = Get-LocString -Key PSLIB_Input0 -ArgumentList $Name
    $key = "INPUT_$($Name.Replace(' ', '_').ToUpperInvariant())"
    Get-VaultValue @PSBoundParameters -Description $description -Key $key
}

<#
.SYNOPSIS
Gets a task variable.

.DESCRIPTION
Gets the value for the specified task variable.

.PARAMETER AsBool
Returns the value as a bool. Returns true if the value converted to a string is "1" or "true" (case insensitive); otherwise false.

.PARAMETER AsInt
Returns the value as an int. Returns the value converted to an int. Returns 0 if the conversion fails.

.PARAMETER Default
Default value to use if the input is null or empty.

.PARAMETER Require
Writes an error to the error pipeline if the input is null or empty.
#>
function Get-TaskVariable {
    [CmdletBinding(DefaultParameterSetName = 'Require')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(ParameterSetName = 'Default')]
        $Default,
        [Parameter(ParameterSetName = 'Require')]
        [switch]$Require,
        [switch]$AsBool,
        [switch]$AsInt)

    $originalErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Stop'
        $description = Get-LocString -Key PSLIB_TaskVariable0 -ArgumentList $Name
        $variableKey = Get-VariableKey -Name $Name
        if ($script:knownVariables.$variableKey.Secret) {
            # Get secret variable. Splatting is required to concisely invoke the correct parameter set.
            $null = $PSBoundParameters.Remove('Name')
            $vaultKey = "SECRET_$variableKey"
            Get-VaultValue @PSBoundParameters -Description $description -Key $vaultKey
        } else {
            # Get public variable.
            $item = $null
            $path = "Env:$variableKey"
            if ((Test-Path -LiteralPath $path) -and ($item = Get-Item -LiteralPath $path).Value) {
                # Intentionally empty. Value was successfully retrieved.
            } elseif (!$script:nonInteractive) {
                # The value wasn't found and the module is running in interactive dev mode.
                # Prompt for the value.
                Set-Item -LiteralPath $path -Value (Read-Host -Prompt $description)
                if (Test-Path -LiteralPath $path) {
                    $item = Get-Item -LiteralPath $path
                }
            }

            # Get the converted value. Splatting is required to concisely invoke the correct parameter set.
            $null = $PSBoundParameters.Remove('Name')
            Get-Value @PSBoundParameters -Description $description -Key $variableKey -Value $item.Value
        }
    } catch {
        $ErrorActionPreference = $originalErrorActionPreference
        Write-Error $_
    }
}

<#
.SYNOPSIS
Gets all job variables available to the task. Requires 2.104.1 agent or higher.

.DESCRIPTION
Gets a snapshot of the current state of all job variables available to the task.
Requires a 2.104.1 agent or higher for full functionality.

Returns an array of objects with the following properties:
    [string]Name
    [string]Value
    [bool]Secret

Limitations on an agent prior to 2.104.1:
 1) The return value does not include all public variables. Only public variables
    that have been added using setVariable are returned.
 2) The name returned for each secret variable is the formatted environment variable
    name, not the actual variable name (unless it was set explicitly at runtime using
    setVariable).
#>
function Get-TaskVariableInfo {
    [CmdletBinding()]
    param()

    foreach ($info in $script:knownVariables.Values) {
        New-Object -TypeName psobject -Property @{
            Name = $info.Name
            Value = Get-TaskVariable -Name $info.Name
            Secret = $info.Secret
        }
    }
}

<#
.SYNOPSIS
Sets a task variable.

.DESCRIPTION
Sets a task variable in the current task context as well as in the current job context. This allows the task variable to retrieved by subsequent tasks within the same job.
#>
function Set-TaskVariable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [string]$Value,
        [switch]$Secret)

    # Once a secret always a secret.
    $variableKey = Get-VariableKey -Name $Name
    [bool]$Secret = $Secret -or $script:knownVariables.$variableKey.Secret
    if ($Secret) {
        $vaultKey = "SECRET_$variableKey"
        if (!$Value) {
            # Clear the secret.
            Write-Verbose "Set $Name = ''"
            $script:vault.Remove($vaultKey)
        } else {
            # Store the secret in the vault.
            Write-Verbose "Set $Name = '********'"
            $script:vault[$vaultKey] = New-Object System.Management.Automation.PSCredential(
                $vaultKey,
                (ConvertTo-SecureString -String $Value -AsPlainText -Force))
        }

        # Clear the environment variable.
        Set-Item -LiteralPath "Env:$variableKey" -Value ''
    } else {
        # Set the environment variable.
        Write-Verbose "Set $Name = '$Value'"
        Set-Item -LiteralPath "Env:$variableKey" -Value $Value
    }

    # Store the metadata.
    $script:knownVariables[$variableKey] = New-Object -TypeName psobject -Property @{
            Name = $name
            Secret = $Secret
        }

    # Persist the variable in the task context.
    Write-SetVariable -Name $Name -Value $Value -Secret:$Secret
}

########################################
# Private functions.
########################################
function Get-VaultValue {
    [CmdletBinding(DefaultParameterSetName = 'Require')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Description,
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [Parameter(ParameterSetName = 'Require')]
        [switch]$Require,
        [Parameter(ParameterSetName = 'Default')]
        [object]$Default,
        [switch]$AsBool,
        [switch]$AsInt)

    # Attempt to get the vault value.
    $value = $null
    if ($psCredential = $script:vault[$Key]) {
        $value = $psCredential.GetNetworkCredential().Password
    } elseif (!$script:nonInteractive) {
        # The value wasn't found. Prompt for the value if running in interactive dev mode.
        $value = Read-Host -Prompt $Description
        if ($value) {
            $script:vault[$Key] = New-Object System.Management.Automation.PSCredential(
                $Key,
                (ConvertTo-SecureString -String $value -AsPlainText -Force))
        }
    }

    Get-Value -Value $value @PSBoundParameters
}

function Get-Value {
    [CmdletBinding(DefaultParameterSetName = 'Require')]
    param(
        [string]$Value,
        [Parameter(Mandatory = $true)]
        [string]$Description,
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [Parameter(ParameterSetName = 'Require')]
        [switch]$Require,
        [Parameter(ParameterSetName = 'Default')]
        [object]$Default,
        [switch]$AsBool,
        [switch]$AsInt)

    $result = $Value
    if ($result) {
        if ($Key -like 'ENDPOINT_AUTH_*') {
            Write-Verbose "$($Key): '********'"
        } else {
            Write-Verbose "$($Key): '$result'"
        }
    } else {
        Write-Verbose "$Key (empty)"

        # Write error if required.
        if ($Require) {
            Write-Error "$(Get-LocString -Key PSLIB_Required0 $Description)"
            return
        }

        # Fallback to the default if provided.
        if ($PSCmdlet.ParameterSetName -eq 'Default') {
            $result = $Default
            $OFS = ' '
            Write-Verbose " Defaulted to: '$result'"
        } else {
            $result = ''
        }
    }

    # Convert to bool if specified.
    if ($AsBool) {
        if ($result -isnot [bool]) {
            $result = "$result" -in '1', 'true'
            Write-Verbose " Converted to bool: $result"
        }

        return $result
    }

    # Convert to int if specified.
    if ($AsInt) {
        if ($result -isnot [int]) {
            try {
                $result = [int]"$result"
            } catch {
                $result = 0
            }

            Write-Verbose " Converted to int: $result"
        }

        return $result
    }

    return $result
}

function Initialize-Inputs {
    # Store endpoints, inputs, and secret variables in the vault.
    foreach ($variable in (Get-ChildItem -Path Env:ENDPOINT_?*, Env:INPUT_?*, Env:SECRET_?*, Env:SECUREFILE_?*)) {
        # Record the secret variable metadata. This is required by Get-TaskVariable to
        # retrieve the value. In a 2.104.1 agent or higher, this metadata will be overwritten
        # when $env:VSTS_SECRET_VARIABLES is processed.
        if ($variable.Name -like 'SECRET_?*') {
            $variableKey = $variable.Name.Substring('SECRET_'.Length)
            $script:knownVariables[$variableKey] = New-Object -TypeName psobject -Property @{
                # This is technically not the variable name (has underscores instead of dots),
                # but it's good enough to make Get-TaskVariable work in a pre-2.104.1 agent
                # where $env:VSTS_SECRET_VARIABLES is not defined.
                Name = $variableKey
                Secret = $true
            }
        }

        # Store the value in the vault.
        $vaultKey = $variable.Name
        if ($variable.Value) {
            $script:vault[$vaultKey] = New-Object System.Management.Automation.PSCredential(
                $vaultKey,
                (ConvertTo-SecureString -String $variable.Value -AsPlainText -Force))
        }

        # Clear the environment variable.
        Remove-Item -LiteralPath "Env:$($variable.Name)"
    }

    # Record the public variable names. Env var added in 2.104.1 agent.
    if ($env:VSTS_PUBLIC_VARIABLES) {
        foreach ($name in (ConvertFrom-Json -InputObject $env:VSTS_PUBLIC_VARIABLES)) {
            $variableKey = Get-VariableKey -Name $name
            $script:knownVariables[$variableKey] = New-Object -TypeName psobject -Property @{
                Name = $name
                Secret = $false
            }
        }

        $env:VSTS_PUBLIC_VARIABLES = ''
    }

    # Record the secret variable names. Env var added in 2.104.1 agent.
    if ($env:VSTS_SECRET_VARIABLES) {
        foreach ($name in (ConvertFrom-Json -InputObject $env:VSTS_SECRET_VARIABLES)) {
            $variableKey = Get-VariableKey -Name $name
            $script:knownVariables[$variableKey] = New-Object -TypeName psobject -Property @{
                Name = $name
                Secret = $true
            }
        }

        $env:VSTS_SECRET_VARIABLES = ''
    }
}

function Get-VariableKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name)

    if ($Name -ne 'agent.jobstatus') {
        $Name = $Name.Replace('.', '_')
    }

    $Name.ToUpperInvariant()
}

# SIG # Begin signature block
# MIIjhAYJKoZIhvcNAQcCoIIjdTCCI3ECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBbqQXYs0XjHxpR
# oVUQXMXqm82JS7ioyoz7KfWP6suubqCCDYEwggX/MIID56ADAgECAhMzAAAB32vw
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
# BgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgxrmbjNFE
# ZLXqkLGTXz2EkXrcvAw0vUe5RMwasP97Y5swNAYKKwYBBAGCNwIBDDEmMCSgEoAQ
# AFQAZQBzAHQAUwBpAGcAbqEOgAxodHRwOi8vdGVzdCAwDQYJKoZIhvcNAQEBBQAE
# ggEAK3Uouf6s0JhMYUFf19WQwBLdzCoJY+dixXXOALlV0jx3ZRofTK1ny5VzCRcd
# HrgqtEonqnEdaxVRDr9kkr7xvUC1HouwysAL+/73+jacoX/KtYCtuzk2YEq5jgyq
# Q9cIuI7f5Jwgl39JPRvg8wyWi6TuCQSXrOBj7zYE/rpNGbCYTEhK57eGl4ju2MRC
# Y9WDDr5j5RLgJuL8uQytimiab6rw9I1aIfJgwiXVrCu1lV4UZvpc9TIO3apRekWW
# DCRYpPykZW8DjWIQecbA2ShVUQmF1IGj2ZZM7qtmOI6ShopfWDMv/heVZGJhh26j
# xYhFF5YDEWnUnN1Vn7jg17n7rKGCEvEwghLtBgorBgEEAYI3AwMBMYIS3TCCEtkG
# CSqGSIb3DQEHAqCCEsowghLGAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFVBgsqhkiG
# 9w0BCRABBKCCAUQEggFAMIIBPAIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCDEJRvcOjuf+NCZGLtzecttHRtqlf3jRymORXHYLhKpdAIGYUTT5qa9GBMy
# MDIxMDkyNDAwMDMxMS42NzhaMASAAgH0oIHUpIHRMIHOMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSkwJwYDVQQLEyBNaWNyb3NvZnQgT3BlcmF0
# aW9ucyBQdWVydG8gUmljbzEmMCQGA1UECxMdVGhhbGVzIFRTUyBFU046MEE1Ni1F
# MzI5LTRENEQxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2Wg
# gg5EMIIE9TCCA92gAwIBAgITMwAAAVt8sLo0ZzfBpwAAAAABWzANBgkqhkiG9w0B
# AQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYD
# VQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAeFw0yMTAxMTQxOTAy
# MTZaFw0yMjA0MTExOTAyMTZaMIHOMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2Fz
# aGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMSkwJwYDVQQLEyBNaWNyb3NvZnQgT3BlcmF0aW9ucyBQdWVydG8g
# UmljbzEmMCQGA1UECxMdVGhhbGVzIFRTUyBFU046MEE1Ni1FMzI5LTRENEQxJTAj
# BgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggEiMA0GCSqGSIb3
# DQEBAQUAA4IBDwAwggEKAoIBAQDIJH+l7PXaoXrLpi5bZ5epcI4g9Y4fiKc/+o+a
# uQkM0p22lbqOCogokqa+VraqlZQ+50/91l+ler3KTUFeXHbVVcGnzaS598hfn0Ta
# FFodUPbvFxokl/GM1UvKuvCTxYkTuBzMzKSwmko3H0GSHegorpMi0K7ip0hcHRoT
# MROxgmsmkPGQ8hDx7PwtseAAGDBbFTrLEnUfI2/H8wHpN0jZWbVSndCm/IqPt15E
# OeDL1F1fXFS9f3g3V1VQQajoR86CbMvnNsv7N1voBF/EG/Tv24wZEeoSGjsBAMOz
# buNP0zFX8Fye4OUfxzVwre3OCGozTeFvgroHsrC52G6kZlvpAgMBAAGjggEbMIIB
# FzAdBgNVHQ4EFgQUZectNYhtt1MgXUx/9eU5yZi6qy4wHwYDVR0jBBgwFoAU1WM6
# XIoxkPNDe3xGG8UzaFqFbVUwVgYDVR0fBE8wTTBLoEmgR4ZFaHR0cDovL2NybC5t
# aWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMvTWljVGltU3RhUENBXzIwMTAt
# MDctMDEuY3JsMFoGCCsGAQUFBwEBBE4wTDBKBggrBgEFBQcwAoY+aHR0cDovL3d3
# dy5taWNyb3NvZnQuY29tL3BraS9jZXJ0cy9NaWNUaW1TdGFQQ0FfMjAxMC0wNy0w
# MS5jcnQwDAYDVR0TAQH/BAIwADATBgNVHSUEDDAKBggrBgEFBQcDCDANBgkqhkiG
# 9w0BAQsFAAOCAQEApzNrO6YTGpnOEHVaJaztWV0YgzFFXYLvf8qvIO5CFZfn5JVF
# dlZaLrevn6TqgBp3sDLcHpxbWoFYVSfB2rvDcJPiAIQdAdOA6GzQ8O7+ChEwEX/C
# jfIEx+ge0Yx4a3jA1oO4nFdA7KI/DCAPAIq1pcH+J6/KSh9J9qxE7HgSQ1nN3W1N
# CEyRB9UcxYRpFuyMzT0AjteuU6ezS516eJmmc6FcfD8ojjTun8g2a9MqlbofTqlh
# /nz2WEP2GBcoccvoR1jrqmKXPNz4Z9bwNAHtflp+G53umRoz8USOrMbDCJHQVw9B
# yS8je2H0q2zlQGMI2Fjh63rBmbr6BGhIA0VlKzCCBnEwggRZoAMCAQICCmEJgSoA
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
# dG8gUmljbzEmMCQGA1UECxMdVGhhbGVzIFRTUyBFU046MEE1Ni1FMzI5LTRENEQx
# JTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WiIwoBATAHBgUr
# DgMCGgMVAAq7QW6mMtK/mBi7VGhVUVv2Ie6moIGDMIGApH4wfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTAwDQYJKoZIhvcNAQEFBQACBQDk9ztLMCIYDzIwMjEw
# OTIzMjE0MzM5WhgPMjAyMTA5MjQyMTQzMzlaMHcwPQYKKwYBBAGEWQoEATEvMC0w
# CgIFAOT3O0sCAQAwCgIBAAICG2UCAf8wBwIBAAICEU4wCgIFAOT4jMsCAQAwNgYK
# KwYBBAGEWQoEAjEoMCYwDAYKKwYBBAGEWQoDAqAKMAgCAQACAwehIKEKMAgCAQAC
# AwGGoDANBgkqhkiG9w0BAQUFAAOBgQBmIQ6Im0zMH7vW+fS5ywG2/BmFSVom7VBl
# q7WqRCejzPV/yWrQiPjHbMD0qvrV9hkB10Adw1M6+yCiviT1BA7l7g4MHCI5lp7k
# JyMIBM7bgYJKt8X3c22D1lt6uweu/i/h7VbgPyJf99uG8ml/BxK7O0wtTJ+py78J
# Ug3bcLCHYjGCAw0wggMJAgEBMIGTMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAy
# MDEwAhMzAAABW3ywujRnN8GnAAAAAAFbMA0GCWCGSAFlAwQCAQUAoIIBSjAaBgkq
# hkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQwLwYJKoZIhvcNAQkEMSIEIA2hNYEfLJeT
# +hcm56dgNaAVEXDDrXkhfgQbfIL80ve4MIH6BgsqhkiG9w0BCRACLzGB6jCB5zCB
# 5DCBvQQgySLgqShjEYeJQhrnBjxwjSe46vTE23t5kNhbUmSwhRkwgZgwgYCkfjB8
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1N
# aWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAVt8sLo0ZzfBpwAAAAAB
# WzAiBCD13HcdDk7Tge3J+zlBnoB5dkdWnRi0t6duJxx2KeY1bTANBgkqhkiG9w0B
# AQsFAASCAQC6EvN/Xc3ZejfKR/IGQjM22fz56kIawhkDNKpFwAqggERzpcObg5ks
# mQ6oGLKA1JXL3W4T9LdltjF1aiTH64rGSwVly2gfbYoa/ifBnYMEOzdBmMNy59Ag
# +jSCFVZL9iCEbaKpftXyYQAuWUe8Qhim+wLnGHg5iKT27LmeQl5v3NWKaJhrIlUX
# 4Y7+XyfCpkJxD5DW4BpghOZyJXFIHsYV/tcjzsW/H7BXnyznDAreMZq+1Tauxu6S
# SjbKTa67vHbUnVLlKUJFyNmewMt8O6F4bUr7mdbgbx9MLUsRNjYC81HfZdz1VkbU
# FlyI1ytrq7rQFR40xaTR/ru/w/OnQAIK
# SIG # End signature block
