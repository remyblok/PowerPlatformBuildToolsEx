$InformationPreference = 'Continue'

function Get-ServiceConnection {
    [CmdletBinding()]
    param([string][ValidateNotNullOrEmpty()]$serviceConnectionRef)

    begin { }

    process {
        $serviceConnection = Get-VstsEndpoint -Name $serviceConnectionRef -Require
    }

    end {
        return $serviceConnection
    }
}

function Get-ConnectionStringFromActiveServiceConnection {
    [CmdletBinding()]
    param(
        [string][ValidateNotNullOrEmpty()] $svcConnSelector = "authenticationType",
        [string] $selectedAuthName
    )

    if ([String]::IsNullOrEmpty($selectedAuthName)) {
        $selectedAuthName = Get-VSTSInput -Name $svcConnSelector -Require
    }
    $selectedAuthRef = Get-VSTSInput -Name $selectedAuthName -Require
    $serviceConnection = Get-ServiceConnection -serviceConnectionRef $selectedAuthRef

    $serviceConnection.url = Get-UrlFromEnvironmentVariables $serviceConnection.url

    if ($selectedAuthName -eq "PowerPlatformEnvironment") {
        $appId = Get-VSTSInput -Name "AppId" -Default "51f81489-12ee-4a9e-aaae-a2591f45987d"
        $redirectUri = Get-VSTSInput -Name "RedirectUri" -Default "app://58145B91-0C36-4500-8554-080854F2AC97"
        
        # Write-Verbose "selected authN using username/password ($($selectedAuthName))."
        $connectingString = "AuthType=OAuth;url=$($serviceConnection.url);UserName=$($serviceConnection.Auth.Parameters.UserName);Password=$($serviceConnection.Auth.Parameters.Password);ClientId=$($appId);RedirectUri=$($redirectUri)"

    } elseif ($selectedAuthName -eq "PowerPlatformSPN") {
        # Write-Verbose "selected authN using SPN ($($selectedAuthName))."
        $connectingString = "AuthType=ClientSecret;url=$($serviceConnection.url);ClientId=$($serviceConnection.Auth.Parameters.applicationId);ClientSecret=$($serviceConnection.Auth.Parameters.clientSecret)"
    }

    return $connectingString;
 }
