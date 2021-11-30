########################################
# Private functions.
########################################
function ConvertFrom-LongFormPath {
    [CmdletBinding()]
    param([string]$Path)

    if ($Path) {
        if ($Path.StartsWith('\\?\UNC')) {
            # E.g. \\?\UNC\server\share -> \\server\share
            return $Path.Substring(1, '\?\UNC'.Length)
        } elseif ($Path.StartsWith('\\?\')) {
            # E.g. \\?\C:\directory -> C:\directory
            return $Path.Substring('\\?\'.Length)
        }
    }

    return $Path
}
function ConvertTo-LongFormPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path)

    [string]$longFormPath = Get-FullNormalizedPath -Path $Path
    if ($longFormPath -and !$longFormPath.StartsWith('\\?')) {
        if ($longFormPath.StartsWith('\\')) {
            # E.g. \\server\share -> \\?\UNC\server\share
            return "\\?\UNC$($longFormPath.Substring(1))"
        } else {
            # E.g. C:\directory -> \\?\C:\directory
            return "\\?\$longFormPath"
        }
    }

    return $longFormPath
}

# TODO: ADD A SWITCH TO EXCLUDE FILES, A SWITCH TO EXCLUDE DIRECTORIES, AND A SWITCH NOT TO FOLLOW REPARSE POINTS.
function Get-DirectoryChildItem {
    [CmdletBinding()]
    param(
        [string]$Path,
        [ValidateNotNullOrEmpty()]
        [Parameter()]
        [string]$Filter = "*",
        [switch]$Force,
        [VstsTaskSdk.FS.FindFlags]$Flags = [VstsTaskSdk.FS.FindFlags]::LargeFetch,
        [VstsTaskSdk.FS.FindInfoLevel]$InfoLevel = [VstsTaskSdk.FS.FindInfoLevel]::Basic,
        [switch]$Recurse)

    $stackOfDirectoryQueues = New-Object System.Collections.Stack
    while ($true) {
        $directoryQueue = New-Object System.Collections.Queue
        $fileQueue = New-Object System.Collections.Queue
        $findData = New-Object VstsTaskSdk.FS.FindData
        $longFormPath = (ConvertTo-LongFormPath $Path)
        $handle = $null
        try {
            $handle = [VstsTaskSdk.FS.NativeMethods]::FindFirstFileEx(
                [System.IO.Path]::Combine($longFormPath, $Filter),
                $InfoLevel,
                $findData,
                [VstsTaskSdk.FS.FindSearchOps]::NameMatch,
                [System.IntPtr]::Zero,
                $Flags)
            if (!$handle.IsInvalid) {
                while ($true) {
                    if ($findData.fileName -notin '.', '..') {
                        $attributes = [VstsTaskSdk.FS.Attributes]$findData.fileAttributes
                        # If the item is hidden, check if $Force is specified.
                        if ($Force -or !$attributes.HasFlag([VstsTaskSdk.FS.Attributes]::Hidden)) {
                            # Create the item.
                            $item = New-Object -TypeName psobject -Property @{
                                'Attributes' = $attributes
                                'FullName' = (ConvertFrom-LongFormPath -Path ([System.IO.Path]::Combine($Path, $findData.fileName)))
                                'Name' = $findData.fileName
                            }
                            # Output directories immediately.
                            if ($item.Attributes.HasFlag([VstsTaskSdk.FS.Attributes]::Directory)) {
                                $item
                                # Append to the directory queue if recursive and default filter.
                                if ($Recurse -and $Filter -eq '*') {
                                    $directoryQueue.Enqueue($item)
                                }
                            } else {
                                # Hold the files until all directories have been output.
                                $fileQueue.Enqueue($item)
                            }
                        }
                    }

                    if (!([VstsTaskSdk.FS.NativeMethods]::FindNextFile($handle, $findData))) { break }

                    if ($handle.IsInvalid) {
                        throw (New-Object -TypeName System.ComponentModel.Win32Exception -ArgumentList @(
                            [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
                            Get-LocString -Key PSLIB_EnumeratingSubdirectoriesFailedForPath0 -ArgumentList $Path
                        ))
                    }
                }
            }
        } finally {
            if ($handle -ne $null) { $handle.Dispose() }
        }

        # If recursive and non-default filter, queue child directories.
        if ($Recurse -and $Filter -ne '*') {
            $findData = New-Object VstsTaskSdk.FS.FindData
            $handle = $null
            try {
                $handle = [VstsTaskSdk.FS.NativeMethods]::FindFirstFileEx(
                    [System.IO.Path]::Combine($longFormPath, '*'),
                    [VstsTaskSdk.FS.FindInfoLevel]::Basic,
                    $findData,
                    [VstsTaskSdk.FS.FindSearchOps]::NameMatch,
                    [System.IntPtr]::Zero,
                    $Flags)
                if (!$handle.IsInvalid) {
                    while ($true) {
                        if ($findData.fileName -notin '.', '..') {
                            $attributes = [VstsTaskSdk.FS.Attributes]$findData.fileAttributes
                            # If the item is hidden, check if $Force is specified.
                            if ($Force -or !$attributes.HasFlag([VstsTaskSdk.FS.Attributes]::Hidden)) {
                                # Collect directories only.
                                if ($attributes.HasFlag([VstsTaskSdk.FS.Attributes]::Directory)) {
                                    # Create the item.
                                    $item = New-Object -TypeName psobject -Property @{
                                        'Attributes' = $attributes
                                        'FullName' = (ConvertFrom-LongFormPath -Path ([System.IO.Path]::Combine($Path, $findData.fileName)))
                                        'Name' = $findData.fileName
                                    }
                                    $directoryQueue.Enqueue($item)
                                }
                            }
                        }

                        if (!([VstsTaskSdk.FS.NativeMethods]::FindNextFile($handle, $findData))) { break }

                        if ($handle.IsInvalid) {
                            throw (New-Object -TypeName System.ComponentModel.Win32Exception -ArgumentList @(
                                [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
                                Get-LocString -Key PSLIB_EnumeratingSubdirectoriesFailedForPath0 -ArgumentList $Path
                            ))
                        }
                    }
                }
            } finally {
                if ($handle -ne $null) { $handle.Dispose() }
            }
        }

        # Output the files.
        $fileQueue

        # Push the directory queue onto the stack if any directories were found.
        if ($directoryQueue.Count) { $stackOfDirectoryQueues.Push($directoryQueue) }

        # Break out of the loop if no more directory queues to process.
        if (!$stackOfDirectoryQueues.Count) { break }

        # Get the next path.
        $directoryQueue = $stackOfDirectoryQueues.Peek()
        $Path = $directoryQueue.Dequeue().FullName

        # Pop the directory queue if it's empty.
        if (!$directoryQueue.Count) { $null = $stackOfDirectoryQueues.Pop() }
    }
}

function Get-FullNormalizedPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path)

    [string]$outPath = $Path
    [uint32]$bufferSize = [VstsTaskSdk.FS.NativeMethods]::GetFullPathName($Path, 0, $null, $null)
    [int]$lastWin32Error = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ($bufferSize -gt 0) {
        $absolutePath = New-Object System.Text.StringBuilder([int]$bufferSize)
        [uint32]$length = [VstsTaskSdk.FS.NativeMethods]::GetFullPathName($Path, $bufferSize, $absolutePath, $null)
        $lastWin32Error = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($length -gt 0) {
            $outPath = $absolutePath.ToString()
        } else  {
            throw (New-Object -TypeName System.ComponentModel.Win32Exception -ArgumentList @(
                $lastWin32Error
                Get-LocString -Key PSLIB_PathLengthNotReturnedFor0 -ArgumentList $Path
            ))
        }
    } else {
        throw (New-Object -TypeName System.ComponentModel.Win32Exception -ArgumentList @(
            $lastWin32Error
            Get-LocString -Key PSLIB_PathLengthNotReturnedFor0 -ArgumentList $Path
        ))
    }

    if ($outPath.EndsWith('\') -and !$outPath.EndsWith(':\')) {
        $outPath = $outPath.TrimEnd('\')
    }

    $outPath
}
# SIG # Begin signature block
# MIIjhAYJKoZIhvcNAQcCoIIjdTCCI3ECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAWnfW6aYPzVGKG
# Jkh+dGciI5wIqiVWZNvlLfO9Sy0gU6CCDYEwggX/MIID56ADAgECAhMzAAAB32vw
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
# BgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgMletFFmf
# kJc5TDtLPGUhejv2TOTjls316mPNQ9KAf3gwNAYKKwYBBAGCNwIBDDEmMCSgEoAQ
# AFQAZQBzAHQAUwBpAGcAbqEOgAxodHRwOi8vdGVzdCAwDQYJKoZIhvcNAQEBBQAE
# ggEAqT2HaWPNyZve1FQLodj/nOAENLPaU/9DHxppFQVpO07FHCmwvWWPyT4M5CFD
# r5eX8Hh8AU/c2J3brDssK8/EyOksHm4YqOmwJaFG4WxoPVDIEYEkBLoN41mcCTtt
# wMvInqe18xxDGHcKNRzp9FOpTd4rG+XoQr+iGj46fczLiVYGXJ9KMEnQKfutpVS4
# a81+/hBoIw6jil8nyjTAbbNKWapztczz0svm+x8aXF2kDoxDoJPCcCghFOX5gsju
# tInhHn+c76KlpOu9xAmE6fkwTEp3k+s2KVhHpokPH8H6VQQhKLnDNbhw2jZINMXQ
# dp01b/hwlJCSBb3p0QPFQKP/mKGCEvEwghLtBgorBgEEAYI3AwMBMYIS3TCCEtkG
# CSqGSIb3DQEHAqCCEsowghLGAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFVBgsqhkiG
# 9w0BCRABBKCCAUQEggFAMIIBPAIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCCk8x7+2J6nPcgCnyo2Gg/7RoC3Z9jyqGO7MS2cYoBDGwIGYUTT20FdGBMy
# MDIxMDkyNDAwMDMxMC44ODJaMASAAgH0oIHUpIHRMIHOMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSkwJwYDVQQLEyBNaWNyb3NvZnQgT3BlcmF0
# aW9ucyBQdWVydG8gUmljbzEmMCQGA1UECxMdVGhhbGVzIFRTUyBFU046QzRCRC1F
# MzdGLTVGRkMxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2Wg
# gg5EMIIE9TCCA92gAwIBAgITMwAAAVdEB2Lcb+i+KgAAAAABVzANBgkqhkiG9w0B
# AQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYD
# VQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAeFw0yMTAxMTQxOTAy
# MTNaFw0yMjA0MTExOTAyMTNaMIHOMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2Fz
# aGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMSkwJwYDVQQLEyBNaWNyb3NvZnQgT3BlcmF0aW9ucyBQdWVydG8g
# UmljbzEmMCQGA1UECxMdVGhhbGVzIFRTUyBFU046QzRCRC1FMzdGLTVGRkMxJTAj
# BgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggEiMA0GCSqGSIb3
# DQEBAQUAA4IBDwAwggEKAoIBAQDebQOnVGb558C/akLV3MDwDYQeHs/uQkK3j6f2
# fEx+DQa+bwHxjKNJVf5YnQWrSk4BxKzrih9dcVQHwXoRybx/U/zoTnPNwibPW8w4
# a5XdCXct3icgtMgXcVXrnEvtmtmQXedMAYP+f9mI0NspXw9HcSiurUC8XTg07mnU
# DG3WtOZTxp1hsGd54koCClUYKqglZYR88DbUYdQB/mcW30nu7fM96BCgHUwMu0rD
# /MpIbd7K43YdAcpDxXaWgIKsFgiSSZhpNIAK0rxwvPr17RqNzCYVkEXuSbc3Q+ZH
# Wih/bnPYJ0obF8gxIRmY8d/m/HLqhDvGx79Fj1/TERH638b5AgMBAAGjggEbMIIB
# FzAdBgNVHQ4EFgQUXTF7u+g4IZ1P5D0zCnRZEfaAqdkwHwYDVR0jBBgwFoAU1WM6
# XIoxkPNDe3xGG8UzaFqFbVUwVgYDVR0fBE8wTTBLoEmgR4ZFaHR0cDovL2NybC5t
# aWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMvTWljVGltU3RhUENBXzIwMTAt
# MDctMDEuY3JsMFoGCCsGAQUFBwEBBE4wTDBKBggrBgEFBQcwAoY+aHR0cDovL3d3
# dy5taWNyb3NvZnQuY29tL3BraS9jZXJ0cy9NaWNUaW1TdGFQQ0FfMjAxMC0wNy0w
# MS5jcnQwDAYDVR0TAQH/BAIwADATBgNVHSUEDDAKBggrBgEFBQcDCDANBgkqhkiG
# 9w0BAQsFAAOCAQEAJXd5AIBul1omcr3Ymy0Zlq+8m+kUsnI1Q4PLXAorUtNbE1ae
# E/AHdkHmHyVnyugzBJO0EQXyoHTe6BPHV7ZkFS/iXMS49KVLsuDQeUXIXLXg+XUZ
# 03ypUYvL4ClGsQ3KBSMzRFM9RB6aKXmoA2+P7iPVI+bSLsJYpP6q7/7BwMO5DOIB
# CyzToHXr/Wf+8aNSSMH3tHqEDN8MXAhS7n/EvTp3LbWhQFh7RBEfCL4EQICyf1p5
# bhc+vPoaw30cl/6qlkjyBNL6BOqhcdc/FLy8CqZuuUDcjQ0TKf1ZgqakWa8QdaNE
# WOz/p+I0jRr25Nm0e9JCrf3aIBRUQR1VblMX/jCCBnEwggRZoAMCAQICCmEJgSoA
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
# dG8gUmljbzEmMCQGA1UECxMdVGhhbGVzIFRTUyBFU046QzRCRC1FMzdGLTVGRkMx
# JTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WiIwoBATAHBgUr
# DgMCGgMVABEt+Eliew320hv4GyEME684GfDyoIGDMIGApH4wfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTAwDQYJKoZIhvcNAQEFBQACBQDk9zs6MCIYDzIwMjEw
# OTIzMjE0MzIyWhgPMjAyMTA5MjQyMTQzMjJaMHcwPQYKKwYBBAGEWQoEATEvMC0w
# CgIFAOT3OzoCAQAwCgIBAAICFFICAf8wBwIBAAICEd0wCgIFAOT4jLoCAQAwNgYK
# KwYBBAGEWQoEAjEoMCYwDAYKKwYBBAGEWQoDAqAKMAgCAQACAwehIKEKMAgCAQAC
# AwGGoDANBgkqhkiG9w0BAQUFAAOBgQBi+iPoEhUHn+s8TUjZxq+safO7IP1sI1PO
# RMFTs9AX92KV+O3HBzBdDT19v+AeuHExgCFf2bBpjyluhnYX2Ua+GShL1RLrVbd+
# Ymnqk20MwvW2UY9AYeQZtHCWq6YjuCqh4cz3Q9l91Y7D0TCtkaQj8qn2WOHhI08n
# 9zXTWT8JWjGCAw0wggMJAgEBMIGTMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAy
# MDEwAhMzAAABV0QHYtxv6L4qAAAAAAFXMA0GCWCGSAFlAwQCAQUAoIIBSjAaBgkq
# hkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQwLwYJKoZIhvcNAQkEMSIEIHW7cEo0nj0V
# EXzNhKJY9CunxgbftglaAvnGo2UxnLDxMIH6BgsqhkiG9w0BCRACLzGB6jCB5zCB
# 5DCBvQQgLFqNDUOr87rrqVLGRDEieFLEY7UMNnRcWVpB7akcoBMwgZgwgYCkfjB8
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1N
# aWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAVdEB2Lcb+i+KgAAAAAB
# VzAiBCAFt3DtOeMeImHQ2OYucbymc16ATQBx4Pk6fenRiit/PTANBgkqhkiG9w0B
# AQsFAASCAQDbVhcceWwMCKU/maf05O+Tistr1xxgyZiKnI8b/D7vFl77kvJ2w4qu
# 1tGDbF/vvpE8XTWwDgvnTe6VK+icqgLEmOADe5IseZlZzxthFLsHNbjyU8FA10Mr
# BrBmKRiOkFSQ8ZuyczKAoq+djqt/Yx6cbF/bSFmZPa4jiUBH8SebXDPT3+Bv2lbN
# eBamVB/vcH0QFDe+43bw2KRI3uGNGlMpT3A9T352cnHxurd8pw5/dVWu8jGsKYg7
# SMi2HKIvso8u0txkXwM+TQWTj/q45YH6bluQxX0l1V4moZ1ir4rQzl0Gn6/Oz99M
# oRXR2NXKVjtOPCzlGwe7bnN1fqGUcVYh
# SIG # End signature block
