<#
.SYNOPSIS
Finds files or directories.

.DESCRIPTION
Finds files or directories using advanced pattern matching.

.PARAMETER LiteralDirectory
Directory to search.

.PARAMETER LegacyPattern
Proprietary pattern format. The LiteralDirectory parameter is used to root any unrooted patterns.

Separate multiple patterns using ";". Escape actual ";" in the path by using ";;".
"?" indicates a wildcard that represents any single character within a path segment.
"*" indicates a wildcard that represents zero or more characters within a path segment.
"**" as the entire path segment indicates a recursive search.
"**" within a path segment indicates a recursive intersegment wildcard.
"+:" (can be omitted) indicates an include pattern.
"-:" indicates an exclude pattern.

The result is from the command is a union of all the matches from the include patterns, minus the matches from the exclude patterns.

.PARAMETER IncludeFiles
Indicates whether to include files in the results.

If neither IncludeFiles or IncludeDirectories is set, then IncludeFiles is assumed.

.PARAMETER IncludeDirectories
Indicates whether to include directories in the results.

If neither IncludeFiles or IncludeDirectories is set, then IncludeFiles is assumed.

.PARAMETER Force
Indicates whether to include hidden items.

.EXAMPLE
Find-VstsFiles -LegacyPattern "C:\Directory\Is?Match.txt"

Given:
C:\Directory\Is1Match.txt
C:\Directory\Is2Match.txt
C:\Directory\IsNotMatch.txt

Returns:
C:\Directory\Is1Match.txt
C:\Directory\Is2Match.txt

.EXAMPLE
Find-VstsFiles -LegacyPattern "C:\Directory\Is*Match.txt"

Given:
C:\Directory\IsOneMatch.txt
C:\Directory\IsTwoMatch.txt
C:\Directory\NonMatch.txt

Returns:
C:\Directory\IsOneMatch.txt
C:\Directory\IsTwoMatch.txt

.EXAMPLE
Find-VstsFiles -LegacyPattern "C:\Directory\**\Match.txt"

Given:
C:\Directory\Match.txt
C:\Directory\NotAMatch.txt
C:\Directory\SubDir\Match.txt
C:\Directory\SubDir\SubSubDir\Match.txt

Returns:
C:\Directory\Match.txt
C:\Directory\SubDir\Match.txt
C:\Directory\SubDir\SubSubDir\Match.txt

.EXAMPLE
Find-VstsFiles -LegacyPattern "C:\Directory\**"

Given:
C:\Directory\One.txt
C:\Directory\SubDir\Two.txt
C:\Directory\SubDir\SubSubDir\Three.txt

Returns:
C:\Directory\One.txt
C:\Directory\SubDir\Two.txt
C:\Directory\SubDir\SubSubDir\Three.txt

.EXAMPLE
Find-VstsFiles -LegacyPattern "C:\Directory\Sub**Match.txt"

Given:
C:\Directory\IsNotAMatch.txt
C:\Directory\SubDir\IsAMatch.txt
C:\Directory\SubDir\IsNot.txt
C:\Directory\SubDir\SubSubDir\IsAMatch.txt
C:\Directory\SubDir\SubSubDir\IsNot.txt

Returns:
C:\Directory\SubDir\IsAMatch.txt
C:\Directory\SubDir\SubSubDir\IsAMatch.txt
#>
function Find-Files {
    [CmdletBinding()]
    param(
        [ValidateNotNullOrEmpty()]
        [Parameter()]
        [string]$LiteralDirectory,
        [Parameter(Mandatory = $true)]
        [string]$LegacyPattern,
        [switch]$IncludeFiles,
        [switch]$IncludeDirectories,
        [switch]$Force)

    # Note, due to subtle implementation details of Get-PathPrefix/Get-PathIterator,
    # this function does not appear to be able to search the root of a drive and other
    # cases where Path.GetDirectoryName() returns empty. More details in Get-PathPrefix.

    Trace-EnteringInvocation $MyInvocation
    if (!$IncludeFiles -and !$IncludeDirectories) {
        $IncludeFiles = $true
    }

    $includePatterns = New-Object System.Collections.Generic.List[string]
    $excludePatterns = New-Object System.Collections.Generic.List[System.Text.RegularExpressions.Regex]
    $LegacyPattern = $LegacyPattern.Replace(';;', "`0")
    foreach ($pattern in $LegacyPattern.Split(';', [System.StringSplitOptions]::RemoveEmptyEntries)) {
        $pattern = $pattern.Replace("`0", ';')
        $isIncludePattern = Test-IsIncludePattern -Pattern ([ref]$pattern)
        if ($LiteralDirectory -and !([System.IO.Path]::IsPathRooted($pattern))) {
            # Use the root directory provided to make the pattern a rooted path.
            $pattern = [System.IO.Path]::Combine($LiteralDirectory, $pattern)
        }

        # Validate pattern does not end with a \.
        if ($pattern[$pattern.Length - 1] -eq [System.IO.Path]::DirectorySeparatorChar) {
            throw (Get-LocString -Key PSLIB_InvalidPattern0 -ArgumentList $pattern)
        }

        if ($isIncludePattern) {
            $includePatterns.Add($pattern)
        } else {
            $excludePatterns.Add((Convert-PatternToRegex -Pattern $pattern))
        }
    }

    $count = 0
    foreach ($path in (Get-MatchingItems -IncludePatterns $includePatterns -ExcludePatterns $excludePatterns -IncludeFiles:$IncludeFiles -IncludeDirectories:$IncludeDirectories -Force:$Force)) {
        $count++
        $path
    }

    Write-Verbose "Total found: $count"
    Trace-LeavingInvocation $MyInvocation
}

########################################
# Private functions.
########################################
function Convert-PatternToRegex {
    [CmdletBinding()]
    param([string]$Pattern)

    $Pattern = [regex]::Escape($Pattern.Replace('\', '/')). # Normalize separators and regex escape.
        Replace('/\*\*/', '((/.+/)|(/))'). # Replace directory globstar.
        Replace('\*\*', '.*'). # Replace remaining globstars with a wildcard that can span directory separators.
        Replace('\*', '[^/]*'). # Replace asterisks with a wildcard that cannot span directory separators.
        # bug: should be '[^/]' instead of '.'
        Replace('\?', '.') # Replace single character wildcards.
    New-Object regex -ArgumentList "^$Pattern`$", ([System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Get-FileNameFilter {
    [CmdletBinding()]
    param([string]$Pattern)

    $index = $Pattern.LastIndexOf('\')
    if ($index -eq -1 -or # Pattern does not contain a backslash.
        !($Pattern = $Pattern.Substring($index + 1)) -or # Pattern ends in a backslash.
        $Pattern.Contains('**')) # Last segment contains an inter-segment wildcard.
    {
        return '*'
    }

    # bug? is this supposed to do substring?
    return $Pattern
}

function Get-MatchingItems {
    [CmdletBinding()]
    param(
        [System.Collections.Generic.List[string]]$IncludePatterns,
        [System.Collections.Generic.List[regex]]$ExcludePatterns,
        [switch]$IncludeFiles,
        [switch]$IncludeDirectories,
        [switch]$Force)

    Trace-EnteringInvocation $MyInvocation
    $allFiles = New-Object System.Collections.Generic.HashSet[string]
    foreach ($pattern in $IncludePatterns) {
        $pathPrefix = Get-PathPrefix -Pattern $pattern
        $fileNameFilter = Get-FileNameFilter -Pattern $pattern
        $patternRegex = Convert-PatternToRegex -Pattern $pattern
        # Iterate over the directories and files under the pathPrefix.
        Get-PathIterator -Path $pathPrefix -Filter $fileNameFilter -IncludeFiles:$IncludeFiles -IncludeDirectories:$IncludeDirectories -Force:$Force |
            ForEach-Object {
                # Normalize separators.
                $normalizedPath = $_.Replace('\', '/')
                # **/times/** will not match C:/fun/times because there isn't a trailing slash.
                # So try both if including directories.
                $alternatePath = "$normalizedPath/" # potential bug: it looks like this will result in a false
                                                    # positive if the item is a regular file and not a directory

                $isMatch = $false
                if ($patternRegex.IsMatch($normalizedPath) -or ($IncludeDirectories -and $patternRegex.IsMatch($alternatePath))) {
                    $isMatch = $true

                    # Test whether the path should be excluded.
                    foreach ($regex in $ExcludePatterns) {
                        if ($regex.IsMatch($normalizedPath) -or ($IncludeDirectories -and $regex.IsMatch($alternatePath))) {
                            $isMatch = $false
                            break
                        }
                    }
                }

                if ($isMatch) {
                    $null = $allFiles.Add($_)
                }
            }
    }

    Trace-Path -Path $allFiles -PassThru
    Trace-LeavingInvocation $MyInvocation
}

function Get-PathIterator {
    [CmdletBinding()]
    param(
        [string]$Path,
        [string]$Filter,
        [switch]$IncludeFiles,
        [switch]$IncludeDirectories,
        [switch]$Force)

    if (!$Path) {
        return
    }

    # bug: this returns the dir without verifying whether exists
    if ($IncludeDirectories) {
        $Path
    }

    Get-DirectoryChildItem -Path $Path -Filter $Filter -Force:$Force -Recurse |
        ForEach-Object {
            if ($_.Attributes.HasFlag([VstsTaskSdk.FS.Attributes]::Directory)) {
                if ($IncludeDirectories) {
                    $_.FullName
                }
            } elseif ($IncludeFiles) {
                $_.FullName
            }
        }
}

function Get-PathPrefix {
    [CmdletBinding()]
    param([string]$Pattern)

    # Note, unable to search root directories is a limitation due to subtleties of this function
    # and downstream code in Get-PathIterator that short-circuits when the path prefix is empty.
    # This function uses Path.GetDirectoryName() to determine the path prefix, which will yield
    # empty in some cases. See the following examples of Path.GetDirectoryName() input => output:
    #       C:/             =>
    #       C:/hello        => C:\
    #       C:/hello/       => C:\hello
    #       C:/hello/world  => C:\hello
    #       C:/hello/world/ => C:\hello\world
    #       C:              =>
    #       C:hello         => C:
    #       C:hello/        => C:hello
    #       /               =>
    #       /hello          => \
    #       /hello/         => \hello
    #       //hello         =>
    #       //hello/        =>
    #       //hello/world   =>
    #       //hello/world/  => \\hello\world

    $index = $Pattern.IndexOfAny([char[]]@('*'[0], '?'[0]))
    if ($index -eq -1) {
        # If no wildcards are found, return the directory name portion of the path.
        # If there is no directory name (file name only in pattern), this will return empty string.
        return [System.IO.Path]::GetDirectoryName($Pattern)
    }

    [System.IO.Path]::GetDirectoryName($Pattern.Substring(0, $index))
}

function Test-IsIncludePattern {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ref]$Pattern)

    # Include patterns start with +: or anything except -:
    # Exclude patterns start with -:
    if ($Pattern.value.StartsWith("+:")) {
        # Remove the prefix.
        $Pattern.value = $Pattern.value.Substring(2)
        $true
    } elseif ($Pattern.value.StartsWith("-:")) {
        # Remove the prefix.
        $Pattern.value = $Pattern.value.Substring(2)
        $false
    } else {
        # No prefix, so leave the string alone.
        $true;
    }
}

# SIG # Begin signature block
# MIIjhAYJKoZIhvcNAQcCoIIjdTCCI3ECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCEgoqbR1JnXZQk
# uBUjU9+jNFOek9RcM71csGRMs2EuZaCCDYEwggX/MIID56ADAgECAhMzAAAB32vw
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
# BgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgtO+Fsaef
# ak+oTlXM3rpDCZ6pm1St1jPgUC6BAch5M9AwNAYKKwYBBAGCNwIBDDEmMCSgEoAQ
# AFQAZQBzAHQAUwBpAGcAbqEOgAxodHRwOi8vdGVzdCAwDQYJKoZIhvcNAQEBBQAE
# ggEAV0+bNFpgXsF91rVAlTN8fbWJ0YUxUPnFE2XdLFCqn6BpD4FntTWpB+BqM6/L
# YwxUgGWJ9GKgi3rN630LgCaECdXqTg+EE/t0qzkR86aZrtmcibOvlg4+HbnBIil1
# 9RCFwtdPxQZkPPcrVxIw6QCdMx9dvV3nL8adOVzKjbulEz3sRkvexHudrSnUHvBn
# pqZdmGs7vlS3BuGa9hj3gwvk5ScG3XrzJ6kwv53bG+NRaCUQGbmnssQsf4++PzPk
# NcMXF0UBJ/ddmK/zXToUjtYdNByvia6uOkirAeTxSdF+mTfQiyQM79ZF5ZLOw9rh
# ifSqNXJ3kQCQNzVm2/ZHkktV56GCEvEwghLtBgorBgEEAYI3AwMBMYIS3TCCEtkG
# CSqGSIb3DQEHAqCCEsowghLGAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFVBgsqhkiG
# 9w0BCRABBKCCAUQEggFAMIIBPAIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCBoMyWwgO/P2wUpeCD2k47/kP55tkk2vySnHtL/8D2UMgIGYUTT5iIxGBMy
# MDIxMDkyNDAwMDMxMS4yMTJaMASAAgH0oIHUpIHRMIHOMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSkwJwYDVQQLEyBNaWNyb3NvZnQgT3BlcmF0
# aW9ucyBQdWVydG8gUmljbzEmMCQGA1UECxMdVGhhbGVzIFRTUyBFU046RjdBNi1F
# MjUxLTE1MEExJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2Wg
# gg5EMIIE9TCCA92gAwIBAgITMwAAAVmf/H5fLOryQwAAAAABWTANBgkqhkiG9w0B
# AQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYD
# VQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAeFw0yMTAxMTQxOTAy
# MTVaFw0yMjA0MTExOTAyMTVaMIHOMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2Fz
# aGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMSkwJwYDVQQLEyBNaWNyb3NvZnQgT3BlcmF0aW9ucyBQdWVydG8g
# UmljbzEmMCQGA1UECxMdVGhhbGVzIFRTUyBFU046RjdBNi1FMjUxLTE1MEExJTAj
# BgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggEiMA0GCSqGSIb3
# DQEBAQUAA4IBDwAwggEKAoIBAQCueMRhyWfEh0RLTSKAaPQBujK6PIBGQrfFoFf5
# jXSLdrTDj981WFOPrEbCJsU8H8yRAwVmk3Oy8ZRMv9d9Nn0Znf0dqcJ2O6ck/dMr
# 2QJkEC2eg/n2hgcMIYua63v7ZgSXWwFxWfKi9iQ3OLcQZ99DK9QvAxQXayI8Gz/o
# tkXQDmksCLP8ULDHmQM97+Y/VRHcKvPojOmHC3Kiq2AMD/jhOfN+9Uk+ZI9n+6rk
# 6Hk14Urw3MymK1aJC92Z9PijQJ26aeKx9bV8ppoF0HIFQs9RPxMvDRLL2dRY1eUD
# +qLwzE/GAKOys2mL0+CMfsTFb1vtf9TJ2GmqEfGy50MZk2TjAgMBAAGjggEbMIIB
# FzAdBgNVHQ4EFgQU9tCphUa8rfrk6yfXiMI8suk3Y+cwHwYDVR0jBBgwFoAU1WM6
# XIoxkPNDe3xGG8UzaFqFbVUwVgYDVR0fBE8wTTBLoEmgR4ZFaHR0cDovL2NybC5t
# aWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMvTWljVGltU3RhUENBXzIwMTAt
# MDctMDEuY3JsMFoGCCsGAQUFBwEBBE4wTDBKBggrBgEFBQcwAoY+aHR0cDovL3d3
# dy5taWNyb3NvZnQuY29tL3BraS9jZXJ0cy9NaWNUaW1TdGFQQ0FfMjAxMC0wNy0w
# MS5jcnQwDAYDVR0TAQH/BAIwADATBgNVHSUEDDAKBggrBgEFBQcDCDANBgkqhkiG
# 9w0BAQsFAAOCAQEAjZFUEugPgYa3xjggFqNynLlGuHrLac8p/mS5ZIdKSZgCaeBF
# A6y1rInmAn9qMqHPCo1TAvjRxRVbxy60jIVp0eRbWOpd2elK/SEwUs+uI+cE0URP
# LyKUIh1WI0VTTxkdrYqhuZyj+frA9K2SOOuDhTc+J+3qwyTqVeyJtS/7AMH1/hh6
# HOI+a37gLkExWPNrHWL7RzOC08cFffe7oZRbOdqB2qXRVtSl7erzMRF50l/LKEH1
# HfjPmKtye7nXOkfeNRrsX3egNL3nFeeiY75qQp4OI0ZKrgHsn/3SpkFGkdXyrwCw
# UQJmZAFLVoo0v9zJHkL/5VLx1aOxjxcyfzt8CTCCBnEwggRZoAMCAQICCmEJgSoA
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
# dG8gUmljbzEmMCQGA1UECxMdVGhhbGVzIFRTUyBFU046RjdBNi1FMjUxLTE1MEEx
# JTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WiIwoBATAHBgUr
# DgMCGgMVACp2ywCPH4TufEglq6WZ171xGbIRoIGDMIGApH4wfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTAwDQYJKoZIhvcNAQEFBQACBQDk9zszMCIYDzIwMjEw
# OTIzMjE0MzE1WhgPMjAyMTA5MjQyMTQzMTVaMHcwPQYKKwYBBAGEWQoEATEvMC0w
# CgIFAOT3OzMCAQAwCgIBAAICJkUCAf8wBwIBAAICEVEwCgIFAOT4jLMCAQAwNgYK
# KwYBBAGEWQoEAjEoMCYwDAYKKwYBBAGEWQoDAqAKMAgCAQACAwehIKEKMAgCAQAC
# AwGGoDANBgkqhkiG9w0BAQUFAAOBgQAQQsduDQk8asnyRCRd9aoOxy7f9ed/P/pz
# G3EeubQEK+q+ikoydpQeuB0kG/NZHf9x3QS4kp80VXeUcs4AD3LFPVoqNR9g2YY3
# FN0BxsBL02uF857ZThkbfQbAjBCn9YOGBdcRu5xaA7wX6YA6DmzhjfS3XklhTdYi
# erEW79ULfzGCAw0wggMJAgEBMIGTMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAy
# MDEwAhMzAAABWZ/8fl8s6vJDAAAAAAFZMA0GCWCGSAFlAwQCAQUAoIIBSjAaBgkq
# hkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQwLwYJKoZIhvcNAQkEMSIEIEOg99o1cByC
# NSW6XRtm3CqGQ6FmMAvAMeHVFO7+AHmUMIH6BgsqhkiG9w0BCRACLzGB6jCB5zCB
# 5DCBvQQgAVgbz78w5nzXks5iU+PnRgPro/6qu/3ypFJ9+q8TQ+gwgZgwgYCkfjB8
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1N
# aWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAVmf/H5fLOryQwAAAAAB
# WTAiBCCM7/Q9Z63SRyuHm7DtdsJQ9jRuYPuTYuRV83g3/dkbOjANBgkqhkiG9w0B
# AQsFAASCAQAzfxAV4oCnHcFvWUWZOMS9r25sVWmc0PlRcLgvhVO3kHJQE58rmQKX
# i69KvaK76fYaUKUdl+NMC/uGzqJvhOAgE2rmt2fjRJX2Sgga42dMX1jOTuCiZbqP
# ZYuovqbNR6X9IhTnBi1Tj7vZQNDkJtEZMdzvkef1vymjbt/wp+TkatxQ/CPV47iA
# xnyh//4NqilO4gDB58t4jjZsdXvbADCTtbuZHz2WzO3EX51snAz97lZEdQ16UAJ9
# dJXWdzIu1pAlLG23gI7m/jnYFnAy/3xhHQA8yzPwt09zOWQoz+mnNAcAHgQuipl9
# cgNdJkM0Ba+t1K3CIlywRas7L6cmPs8t
# SIG # End signature block
