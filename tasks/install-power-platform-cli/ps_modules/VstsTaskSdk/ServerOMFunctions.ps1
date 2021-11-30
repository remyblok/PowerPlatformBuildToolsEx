<#
.SYNOPSIS
Gets assembly reference information.

.DESCRIPTION
Not supported for use during task execution. This function is only intended to help developers resolve the minimal set of DLLs that need to be bundled when consuming the VSTS REST SDK or TFS Extended Client SDK. The interface and output may change between patch releases of the VSTS Task SDK.

Only a subset of the referenced assemblies may actually be required, depending on the functionality used by your task. It is best to bundle only the DLLs required for your scenario.

Walks an assembly's references to determine all of it's dependencies. Also walks the references of the dependencies, and so on until all nested dependencies have been traversed. Dependencies are searched for in the directory of the specified assembly. NET Framework assemblies are omitted.

See https://github.com/Microsoft/vsts-task-lib/tree/master/powershell/Docs/UsingOM.md for reliable usage when working with the TFS extended client SDK from a task.

.PARAMETER LiteralPath
Assembly to walk.

.EXAMPLE
Get-VstsAssemblyReference -LiteralPath C:\nuget\microsoft.teamfoundationserver.client.14.102.0\lib\net45\Microsoft.TeamFoundation.Build2.WebApi.dll
#>
function Get-AssemblyReference {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LiteralPath)

    $ErrorActionPreference = 'Stop'
    Write-Warning "Not supported for use during task execution. This function is only intended to help developers resolve the minimal set of DLLs that need to be bundled when consuming the VSTS REST SDK or TFS Extended Client SDK. The interface and output may change between patch releases of the VSTS Task SDK."
    Write-Output ''
    Write-Warning "Only a subset of the referenced assemblies may actually be required, depending on the functionality used by your task. It is best to bundle only the DLLs required for your scenario."
    $directory = [System.IO.Path]::GetDirectoryName($LiteralPath)
    $hashtable = @{ }
    $queue = @( [System.Reflection.Assembly]::ReflectionOnlyLoadFrom($LiteralPath).GetName() )
    while ($queue.Count) {
        # Add a blank line between assemblies.
        Write-Output ''

        # Pop.
        $assemblyName = $queue[0]
        $queue = @( $queue | Select-Object -Skip 1 )

        # Attempt to find the assembly in the same directory.
        $assembly = $null
        $path = "$directory\$($assemblyName.Name).dll"
        if ((Test-Path -LiteralPath $path -PathType Leaf)) {
            $assembly = [System.Reflection.Assembly]::ReflectionOnlyLoadFrom($path)
        } else {
            $path = "$directory\$($assemblyName.Name).exe"
            if ((Test-Path -LiteralPath $path -PathType Leaf)) {
                $assembly = [System.Reflection.Assembly]::ReflectionOnlyLoadFrom($path)
            }
        }

        # Make sure the assembly full name matches, not just the file name.
        if ($assembly -and $assembly.GetName().FullName -ne $assemblyName.FullName) {
            $assembly = $null
        }

        # Print the assembly.
        if ($assembly) {
            Write-Output $assemblyName.FullName
        } else {
            if ($assemblyName.FullName -eq 'Newtonsoft.Json, Version=6.0.0.0, Culture=neutral, PublicKeyToken=30ad4fe6b2a6aeed') {
                Write-Warning "*** NOT FOUND $($assemblyName.FullName) *** This is an expected condition when using the HTTP clients from the 15.x VSTS REST SDK. Use Get-VstsVssHttpClient to load the HTTP clients (which applies a binding redirect assembly resolver for Newtonsoft.Json). Otherwise you will need to manage the binding redirect yourself."
            } else {
                Write-Warning "*** NOT FOUND $($assemblyName.FullName) ***"
            }
    
            continue
        }

        # Walk the references.
        $refAssemblyNames = @( $assembly.GetReferencedAssemblies() )
        for ($i = 0 ; $i -lt $refAssemblyNames.Count ; $i++) {
            $refAssemblyName = $refAssemblyNames[$i]

            # Skip framework assemblies.
            $fxPaths = @(
                "$env:windir\Microsoft.Net\Framework64\v4.0.30319\$($refAssemblyName.Name).dll"
                "$env:windir\Microsoft.Net\Framework64\v4.0.30319\WPF\$($refAssemblyName.Name).dll"
            )
            $fxPath = $fxPaths |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
                Where-Object { [System.Reflection.Assembly]::ReflectionOnlyLoadFrom($_).GetName().FullName -eq $refAssemblyName.FullName }
            if ($fxPath) {
                continue
            }

            # Print the reference.
            Write-Output "    $($refAssemblyName.FullName)"

            # Add new references to the queue.
            if (!$hashtable[$refAssemblyName.FullName]) {
                $queue += $refAssemblyName
                $hashtable[$refAssemblyName.FullName] = $true
            }
        }
    }
}

<#
.SYNOPSIS
Gets a credentials object that can be used with the TFS extended client SDK.

.DESCRIPTION
The agent job token is used to construct the credentials object. The identity associated with the token depends on the scope selected in the build/release definition (either the project collection build/release service identity, or the project build/release service identity).

Refer to Get-VstsTfsService for a more simple to get a TFS service object.

*** DO NOT USE Agent.ServerOMDirectory *** See https://github.com/Microsoft/vsts-task-lib/tree/master/powershell/Docs/UsingOM.md for reliable usage when working with the TFS extended client SDK from a task.

.PARAMETER OMDirectory
Directory where the extended client object model DLLs are located. If the DLLs for the credential types are not already loaded, an attempt will be made to automatically load the required DLLs from the object model directory.

If not specified, defaults to the directory of the entry script for the task.

*** DO NOT USE Agent.ServerOMDirectory *** See https://github.com/Microsoft/vsts-task-lib/tree/master/powershell/Docs/UsingOM.md for reliable usage when working with the TFS extended client SDK from a task.

.EXAMPLE
#
# Refer to Get-VstsTfsService for a more simple way to get a TFS service object.
#
$credentials = Get-VstsTfsClientCredentials
Add-Type -LiteralPath "$PSScriptRoot\Microsoft.TeamFoundation.VersionControl.Client.dll"
$tfsTeamProjectCollection = New-Object Microsoft.TeamFoundation.Client.TfsTeamProjectCollection(
    (Get-VstsTaskVariable -Name 'System.TeamFoundationCollectionUri' -Require),
    $credentials)
$versionControlServer = $tfsTeamProjectCollection.GetService([Microsoft.TeamFoundation.VersionControl.Client.VersionControlServer])
$versionControlServer.GetItems('$/*').Items | Format-List
#>
function Get-TfsClientCredentials {
    [CmdletBinding()]
    param([string]$OMDirectory)

    Trace-EnteringInvocation -InvocationInfo $MyInvocation
    $originalErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Stop'

        # Get the endpoint.
        $endpoint = Get-Endpoint -Name SystemVssConnection -Require

        # Validate the type can be found.
        $null = Get-OMType -TypeName 'Microsoft.TeamFoundation.Client.TfsClientCredentials' -OMKind 'ExtendedClient' -OMDirectory $OMDirectory -Require

        # Construct the credentials.
        $credentials = New-Object Microsoft.TeamFoundation.Client.TfsClientCredentials($false) # Do not use default credentials.
        $credentials.AllowInteractive = $false
        $credentials.Federated = New-Object Microsoft.TeamFoundation.Client.OAuthTokenCredential([string]$endpoint.auth.parameters.AccessToken)
        return $credentials
    } catch {
        $ErrorActionPreference = $originalErrorActionPreference
        Write-Error $_
    } finally {
        Trace-LeavingInvocation -InvocationInfo $MyInvocation
    }
}

<#
.SYNOPSIS
Gets a TFS extended client service.

.DESCRIPTION
Gets an instance of an ITfsTeamProjectCollectionObject.

*** DO NOT USE Agent.ServerOMDirectory *** See https://github.com/Microsoft/vsts-task-lib/tree/master/powershell/Docs/UsingOM.md for reliable usage when working with the TFS extended client SDK from a task.

.PARAMETER TypeName
Namespace-qualified type name of the service to get.

.PARAMETER OMDirectory
Directory where the extended client object model DLLs are located. If the DLLs for the types are not already loaded, an attempt will be made to automatically load the required DLLs from the object model directory.

If not specified, defaults to the directory of the entry script for the task.

*** DO NOT USE Agent.ServerOMDirectory *** See https://github.com/Microsoft/vsts-task-lib/tree/master/powershell/Docs/UsingOM.md for reliable usage when working with the TFS extended client SDK from a task.

.PARAMETER Uri
URI to use when initializing the service. If not specified, defaults to System.TeamFoundationCollectionUri.

.PARAMETER TfsClientCredentials
Credentials to use when initializing the service. If not specified, the default uses the agent job token to construct the credentials object. The identity associated with the token depends on the scope selected in the build/release definition (either the project collection build/release service identity, or the project build/release service identity).

.EXAMPLE
$versionControlServer = Get-VstsTfsService -TypeName Microsoft.TeamFoundation.VersionControl.Client.VersionControlServer
$versionControlServer.GetItems('$/*').Items | Format-List
#>
function Get-TfsService {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TypeName,

        [string]$OMDirectory,

        [string]$Uri,

        $TfsClientCredentials)

    Trace-EnteringInvocation -InvocationInfo $MyInvocation
    $originalErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Stop'

        # Default the URI to the collection URI.
        if (!$Uri) {
            $Uri = Get-TaskVariable -Name System.TeamFoundationCollectionUri -Require
        }

        # Default the credentials.
        if (!$TfsClientCredentials) {
            $TfsClientCredentials = Get-TfsClientCredentials -OMDirectory $OMDirectory
        }

        # Validate the project collection type can be loaded.
        $null = Get-OMType -TypeName 'Microsoft.TeamFoundation.Client.TfsTeamProjectCollection' -OMKind 'ExtendedClient' -OMDirectory $OMDirectory -Require

        # Load the project collection object.
        $tfsTeamProjectCollection = New-Object Microsoft.TeamFoundation.Client.TfsTeamProjectCollection($Uri, $TfsClientCredentials)

        # Validate the requested type can be loaded.
        $type = Get-OMType -TypeName $TypeName -OMKind 'ExtendedClient' -OMDirectory $OMDirectory -Require

        # Return the service object.
        return $tfsTeamProjectCollection.GetService($type)
    } catch {
        $ErrorActionPreference = $originalErrorActionPreference
        Write-Error $_
    } finally {
        Trace-LeavingInvocation -InvocationInfo $MyInvocation
    }
}

<#
.SYNOPSIS
Gets a credentials object that can be used with the VSTS REST SDK.

.DESCRIPTION
The agent job token is used to construct the credentials object. The identity associated with the token depends on the scope selected in the build/release definition (either the project collection build/release service identity, or the project service build/release identity).

Refer to Get-VstsVssHttpClient for a more simple to get a VSS HTTP client.

*** DO NOT USE Agent.ServerOMDirectory *** See https://github.com/Microsoft/vsts-task-lib/tree/master/powershell/Docs/UsingOM.md for reliable usage when working with the VSTS REST SDK from a task.

.PARAMETER OMDirectory
Directory where the REST client object model DLLs are located. If the DLLs for the credential types are not already loaded, an attempt will be made to automatically load the required DLLs from the object model directory.

If not specified, defaults to the directory of the entry script for the task.

*** DO NOT USE Agent.ServerOMDirectory *** See https://github.com/Microsoft/vsts-task-lib/tree/master/powershell/Docs/UsingOM.md for reliable usage when working with the VSTS REST SDK from a task.

.EXAMPLE
#
# Refer to Get-VstsTfsService for a more simple way to get a TFS service object.
#
# This example works using the 14.x .NET SDK. A Newtonsoft.Json 6.0 to 8.0 binding
# redirect may be required when working with the 15.x SDK. Or use Get-VstsVssHttpClient
# to avoid managing the binding redirect.
#
$vssCredentials = Get-VstsVssCredentials
$collectionUrl = New-Object System.Uri((Get-VstsTaskVariable -Name 'System.TeamFoundationCollectionUri' -Require))
Add-Type -LiteralPath "$PSScriptRoot\Microsoft.TeamFoundation.Core.WebApi.dll"
$projectHttpClient = New-Object Microsoft.TeamFoundation.Core.WebApi.ProjectHttpClient($collectionUrl, $vssCredentials)
$projectHttpClient.GetProjects().Result
#>
function Get-VssCredentials {
    [CmdletBinding()]
    param([string]$OMDirectory)

    Trace-EnteringInvocation -InvocationInfo $MyInvocation
    $originalErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Stop'

        # Get the endpoint.
        $endpoint = Get-Endpoint -Name SystemVssConnection -Require

        # Check if the VssOAuthAccessTokenCredential type is available.
        if ((Get-OMType -TypeName 'Microsoft.VisualStudio.Services.OAuth.VssOAuthAccessTokenCredential' -OMKind 'WebApi' -OMDirectory $OMDirectory)) {
            # Create the federated credential.
            $federatedCredential = New-Object Microsoft.VisualStudio.Services.OAuth.VssOAuthAccessTokenCredential($endpoint.auth.parameters.AccessToken)
        } else {
            # Validate the fallback type can be loaded.
            $null = Get-OMType -TypeName 'Microsoft.VisualStudio.Services.Client.VssOAuthCredential' -OMKind 'WebApi' -OMDirectory $OMDirectory -Require

            # Create the federated credential.
            $federatedCredential = New-Object Microsoft.VisualStudio.Services.Client.VssOAuthCredential($endpoint.auth.parameters.AccessToken)
        }

        # Return the credentials.
        return New-Object Microsoft.VisualStudio.Services.Common.VssCredentials(
            (New-Object Microsoft.VisualStudio.Services.Common.WindowsCredential($false)), # Do not use default credentials.
            $federatedCredential,
            [Microsoft.VisualStudio.Services.Common.CredentialPromptType]::DoNotPrompt)
    } catch {
        $ErrorActionPreference = $originalErrorActionPreference
        Write-Error $_
    } finally {
        Trace-LeavingInvocation -InvocationInfo $MyInvocation
    }
}

<#
.SYNOPSIS
Gets a VSS HTTP client.

.DESCRIPTION
Gets an instance of an VSS HTTP client.

*** DO NOT USE Agent.ServerOMDirectory *** See https://github.com/Microsoft/vsts-task-lib/tree/master/powershell/Docs/UsingOM.md for reliable usage when working with the VSTS REST SDK from a task.

.PARAMETER TypeName
Namespace-qualified type name of the HTTP client to get.

.PARAMETER OMDirectory
Directory where the REST client object model DLLs are located. If the DLLs for the credential types are not already loaded, an attempt will be made to automatically load the required DLLs from the object model directory.

If not specified, defaults to the directory of the entry script for the task.

*** DO NOT USE Agent.ServerOMDirectory *** See https://github.com/Microsoft/vsts-task-lib/tree/master/powershell/Docs/UsingOM.md for reliable usage when working with the VSTS REST SDK from a task.

# .PARAMETER Uri
# URI to use when initializing the HTTP client. If not specified, defaults to System.TeamFoundationCollectionUri.

# .PARAMETER VssCredentials
# Credentials to use when initializing the HTTP client. If not specified, the default uses the agent job token to construct the credentials object. The identity associated with the token depends on the scope selected in the build/release definition (either the project collection build/release service identity, or the project build/release service identity).

# .PARAMETER WebProxy
# WebProxy to use when initializing the HTTP client. If not specified, the default uses the proxy configuration agent current has.

# .PARAMETER ClientCert
# ClientCert to use when initializing the HTTP client. If not specified, the default uses the client certificate agent current has.

# .PARAMETER IgnoreSslError
# Skip SSL server certificate validation on all requests made by this HTTP client. If not specified, the default is to validate SSL server certificate.

.EXAMPLE
$projectHttpClient = Get-VstsVssHttpClient -TypeName Microsoft.TeamFoundation.Core.WebApi.ProjectHttpClient
$projectHttpClient.GetProjects().Result
#>
function Get-VssHttpClient {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TypeName,

        [string]$OMDirectory,

        [string]$Uri,

        $VssCredentials,
        
        $WebProxy = (Get-WebProxy),
        
        $ClientCert = (Get-ClientCertificate),
        
        [switch]$IgnoreSslError)

    Trace-EnteringInvocation -InvocationInfo $MyInvocation
    $originalErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Stop'

        # Default the URI to the collection URI.
        if (!$Uri) {
            $Uri = Get-TaskVariable -Name System.TeamFoundationCollectionUri -Require
        }

        # Cast the URI.
        [uri]$Uri = New-Object System.Uri($Uri)

        # Default the credentials.
        if (!$VssCredentials) {
            $VssCredentials = Get-VssCredentials -OMDirectory $OMDirectory
        }

        # Validate the type can be loaded.
        $null = Get-OMType -TypeName $TypeName -OMKind 'WebApi' -OMDirectory $OMDirectory -Require

        # Update proxy setting for vss http client
        [Microsoft.VisualStudio.Services.Common.VssHttpMessageHandler]::DefaultWebProxy = $WebProxy
        
        # Update client certificate setting for vss http client
        $null = Get-OMType -TypeName 'Microsoft.VisualStudio.Services.Common.VssHttpRequestSettings' -OMKind 'WebApi' -OMDirectory $OMDirectory -Require
        $null = Get-OMType -TypeName 'Microsoft.VisualStudio.Services.WebApi.VssClientHttpRequestSettings' -OMKind 'WebApi' -OMDirectory $OMDirectory -Require
        [Microsoft.VisualStudio.Services.Common.VssHttpRequestSettings]$Settings = [Microsoft.VisualStudio.Services.WebApi.VssClientHttpRequestSettings]::Default.Clone()

        if ($ClientCert) {
            $null = Get-OMType -TypeName 'Microsoft.VisualStudio.Services.WebApi.VssClientCertificateManager' -OMKind 'WebApi' -OMDirectory $OMDirectory -Require
            $null = [Microsoft.VisualStudio.Services.WebApi.VssClientCertificateManager]::Instance.ClientCertificates.Add($ClientCert)
            
            $Settings.ClientCertificateManager = [Microsoft.VisualStudio.Services.WebApi.VssClientCertificateManager]::Instance
        }        

        # Skip SSL server certificate validation
        [bool]$SkipCertValidation = (Get-TaskVariable -Name Agent.SkipCertValidation -AsBool) -or $IgnoreSslError
        if ($SkipCertValidation) {
            if ($Settings.GetType().GetProperty('ServerCertificateValidationCallback')) {
                Write-Verbose "Ignore any SSL server certificate validation errors.";
                $Settings.ServerCertificateValidationCallback = [VstsTaskSdk.VstsHttpHandlerSettings]::UnsafeSkipServerCertificateValidation
            }
            else {
                # OMDirectory has older version of Microsoft.VisualStudio.Services.Common.dll
                Write-Verbose "The version of 'Microsoft.VisualStudio.Services.Common.dll' does not support skip SSL server certificate validation."
            }
        }

        # Try to construct the HTTP client.
        Write-Verbose "Constructing HTTP client."
        try {
            return New-Object $TypeName($Uri, $VssCredentials, $Settings)
        } catch {
            # Rethrow if the exception is not due to Newtonsoft.Json DLL not found.
            if ($_.Exception.InnerException -isnot [System.IO.FileNotFoundException] -or
                $_.Exception.InnerException.FileName -notlike 'Newtonsoft.Json, *') {

                throw
            }

            # Default the OMDirectory to the directory of the entry script for the task.
            if (!$OMDirectory) {
                $OMDirectory = [System.IO.Path]::GetFullPath("$PSScriptRoot\..\..")
                Write-Verbose "Defaulted OM directory to: '$OMDirectory'"
            }

            # Test if the Newtonsoft.Json DLL exists in the OM directory.
            $newtonsoftDll = [System.IO.Path]::Combine($OMDirectory, "Newtonsoft.Json.dll")
            Write-Verbose "Testing file path: '$newtonsoftDll'"
            if (!(Test-Path -LiteralPath $newtonsoftDll -PathType Leaf)) {
                Write-Verbose 'Not found. Rethrowing exception.'
                throw
            }

            # Add a binding redirect and try again. Parts of the Dev15 preview SDK have a
            # dependency on the 6.0.0.0 Newtonsoft.Json DLL, while other parts reference
            # the 8.0.0.0 Newtonsoft.Json DLL.
            Write-Verbose "Adding assembly resolver."
            $onAssemblyResolve = [System.ResolveEventHandler] {
                param($sender, $e)

                if ($e.Name -like 'Newtonsoft.Json, *') {
                    Write-Verbose "Resolving '$($e.Name)'"
                    return [System.Reflection.Assembly]::LoadFrom($newtonsoftDll)
                }

                Write-Verbose "Unable to resolve assembly name '$($e.Name)'"
                return $null
            }
            [System.AppDomain]::CurrentDomain.add_AssemblyResolve($onAssemblyResolve)
            try {
                # Try again to construct the HTTP client.
                Write-Verbose "Trying again to construct the HTTP client."
                return New-Object $TypeName($Uri, $VssCredentials, $Settings)
            } finally {
                # Unregister the assembly resolver.
                Write-Verbose "Removing assemlby resolver."
                [System.AppDomain]::CurrentDomain.remove_AssemblyResolve($onAssemblyResolve)
            }
        }
    } catch {
        $ErrorActionPreference = $originalErrorActionPreference
        Write-Error $_
    } finally {
        Trace-LeavingInvocation -InvocationInfo $MyInvocation
    }
}

<#
.SYNOPSIS
Gets a VstsTaskSdk.VstsWebProxy

.DESCRIPTION
Gets an instance of a VstsTaskSdk.VstsWebProxy that has same proxy configuration as Build/Release agent.

VstsTaskSdk.VstsWebProxy implement System.Net.IWebProxy interface.

.EXAMPLE
$webProxy = Get-VstsWebProxy
$webProxy.GetProxy(New-Object System.Uri("https://github.com/Microsoft/vsts-task-lib"))
#>
function Get-WebProxy {
    [CmdletBinding()]
    param()

    Trace-EnteringInvocation -InvocationInfo $MyInvocation
    try {
        # Min agent version that supports proxy
        Assert-Agent -Minimum '2.105.7'

        $proxyUrl = Get-TaskVariable -Name Agent.ProxyUrl
        $proxyUserName = Get-TaskVariable -Name Agent.ProxyUserName
        $proxyPassword = Get-TaskVariable -Name Agent.ProxyPassword
        $proxyBypassListJson = Get-TaskVariable -Name Agent.ProxyBypassList
        [string[]]$ProxyBypassList = ConvertFrom-Json -InputObject $ProxyBypassListJson
        
        return New-Object -TypeName VstsTaskSdk.VstsWebProxy -ArgumentList @($proxyUrl, $proxyUserName, $proxyPassword, $proxyBypassList)
    }
    finally {
        Trace-LeavingInvocation -InvocationInfo $MyInvocation
    }
}

<#
.SYNOPSIS
Gets a client certificate for current connected TFS instance

.DESCRIPTION
Gets an instance of a X509Certificate2 that is the client certificate Build/Release agent used.

.EXAMPLE
$x509cert = Get-ClientCertificate
WebRequestHandler.ClientCertificates.Add(x509cert)
#>
function Get-ClientCertificate {
    [CmdletBinding()]
    param()

    Trace-EnteringInvocation -InvocationInfo $MyInvocation
    try {
        # Min agent version that supports client certificate
        Assert-Agent -Minimum '2.122.0'

        [string]$clientCert = Get-TaskVariable -Name Agent.ClientCertArchive
        [string]$clientCertPassword = Get-TaskVariable -Name Agent.ClientCertPassword
        
        if ($clientCert -and (Test-Path -LiteralPath $clientCert -PathType Leaf)) {
            return New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @($clientCert, $clientCertPassword)
        }        
    }
    finally {
        Trace-LeavingInvocation -InvocationInfo $MyInvocation
    }
}

########################################
# Private functions.
########################################
function Get-OMType {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TypeName,

        [ValidateSet('ExtendedClient', 'WebApi')]
        [Parameter(Mandatory = $true)]
        [string]$OMKind,

        [string]$OMDirectory,

        [switch]$Require)

    Trace-EnteringInvocation -InvocationInfo $MyInvocation
    try {
        # Default the OMDirectory to the directory of the entry script for the task.
        if (!$OMDirectory) {
            $OMDirectory = [System.IO.Path]::GetFullPath("$PSScriptRoot\..\..")
            Write-Verbose "Defaulted OM directory to: '$OMDirectory'"
        }

        # Try to load the type.
        $errorRecord = $null
        Write-Verbose "Testing whether type can be loaded: '$TypeName'"
        $ErrorActionPreference = 'Ignore'
        try {
            # Failure when attempting to cast a string to a type, transfers control to the
            # catch handler even when the error action preference is ignore. The error action
            # is set to Ignore so the $Error variable is not polluted.
            $type = [type]$TypeName

            # Success.
            Write-Verbose "The type was loaded successfully."
            return $type
        } catch {
            # Store the error record.
            $errorRecord = $_
        }

        $ErrorActionPreference = 'Stop'
        Write-Verbose "The type was not loaded."

        # Build a list of candidate DLL file paths from the namespace.
        $dllPaths = @( )
        $namespace = $TypeName
        while ($namespace.LastIndexOf('.') -gt 0) {
            # Trim the next segment from the namespace.
            $namespace = $namespace.SubString(0, $namespace.LastIndexOf('.'))

            # Derive potential DLL file paths based on the namespace and OM kind (i.e. extended client vs web API).
            if ($OMKind -eq 'ExtendedClient') {
                if ($namespace -like 'Microsoft.TeamFoundation.*') {
                    $dllPaths += [System.IO.Path]::Combine($OMDirectory, "$namespace.dll")
                }
            } else {
                if ($namespace -like 'Microsoft.TeamFoundation.*' -or
                    $namespace -like 'Microsoft.VisualStudio.Services' -or
                    $namespace -like 'Microsoft.VisualStudio.Services.*') {

                    $dllPaths += [System.IO.Path]::Combine($OMDirectory, "$namespace.WebApi.dll")
                    $dllPaths += [System.IO.Path]::Combine($OMDirectory, "$namespace.dll")
                }
            }
        }

        foreach ($dllPath in $dllPaths) {
            # Check whether the DLL exists.
            Write-Verbose "Testing leaf path: '$dllPath'"
            if (!(Test-Path -PathType Leaf -LiteralPath "$dllPath")) {
                Write-Verbose "Not found."
                continue
            }

            # Load the DLL.
            Write-Verbose "Loading assembly: $dllPath"
            try {
                Add-Type -LiteralPath $dllPath
            } catch {
                # Write the information to the verbose stream and proceed to attempt to load the requested type.
                #
                # The requested type may successfully load now. For example, the type used with the 14.0 Web API for the
                # federated credential (VssOAuthCredential) resides in Microsoft.VisualStudio.Services.Client.dll. Even
                # though loading the DLL results in a ReflectionTypeLoadException when Microsoft.ServiceBus.dll (approx 3.75mb)
                # is not present, enough types are loaded to use the VssOAuthCredential federated credential with the Web API
                # HTTP clients.
                Write-Verbose "$($_.Exception.GetType().FullName): $($_.Exception.Message)"
                if ($_.Exception -is [System.Reflection.ReflectionTypeLoadException]) {
                    for ($i = 0 ; $i -lt $_.Exception.LoaderExceptions.Length ; $i++) {
                        $loaderException = $_.Exception.LoaderExceptions[$i]
                        Write-Verbose "LoaderExceptions[$i]: $($loaderException.GetType().FullName): $($loaderException.Message)"
                    }
                }
            }

            # Try to load the type.
            Write-Verbose "Testing whether type can be loaded: '$TypeName'"
            $ErrorActionPreference = 'Ignore'
            try {
                # Failure when attempting to cast a string to a type, transfers control to the
                # catch handler even when the error action preference is ignore. The error action
                # is set to Ignore so the $Error variable is not polluted.
                $type = [type]$TypeName

                # Success.
                Write-Verbose "The type was loaded successfully."
                return $type
            } catch {
                $errorRecord = $_
            }

            $ErrorActionPreference = 'Stop'
            Write-Verbose "The type was not loaded."
        }

        # Check whether to propagate the error.
        if ($Require) {
            Write-Error $errorRecord
        }
    } finally {
        Trace-LeavingInvocation -InvocationInfo $MyInvocation
    }
}

# SIG # Begin signature block
# MIIjhAYJKoZIhvcNAQcCoIIjdTCCI3ECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDHnexhTvdi65ta
# GC2EoafY//c7J46ZI88EwI2sfoBaAqCCDYEwggX/MIID56ADAgECAhMzAAAB32vw
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
# BgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgkBXrdJYV
# xlW9WevRPbyUrdEHJSyYEY2EaCYjZYk11xEwNAYKKwYBBAGCNwIBDDEmMCSgEoAQ
# AFQAZQBzAHQAUwBpAGcAbqEOgAxodHRwOi8vdGVzdCAwDQYJKoZIhvcNAQEBBQAE
# ggEAnV3XoWTZ2X/+TCSmrugdUa6KrXCUHdHri6NH4qM7TBDSvnCX0rkJuwFUleba
# Sg7zsEBXxtOvyMhctHiRQAkAxY5GUBWksXHwOCApNudiTKFSYQLOPTMJqCwr4MzE
# 4zvQnaQG0hhrFg1oaZ3v2yojFVMHvXgHSV9JriTXIp9R75KkNRfo3e0lQoFFSP1H
# 1PFz0jHdcdJ0QE/+Zfde1rZXBjpa8dLEjIxG3Qgm6U5vg1gQ824dP7sK19WRxbWd
# JGzi2/zrXbm1H8ORSiNgwfz+QJck9yGMJfiahSeOKaOug6v54eG3EVEXLyYQ/PvL
# pF1ANTaYs4bHMtkcOffauwJnvaGCEvEwghLtBgorBgEEAYI3AwMBMYIS3TCCEtkG
# CSqGSIb3DQEHAqCCEsowghLGAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFVBgsqhkiG
# 9w0BCRABBKCCAUQEggFAMIIBPAIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCBIoNTx62FLS3iNQT/TUbHEiI3PrZXuNBaPEm0CjogSaQIGYUTT20FkGBMy
# MDIxMDkyNDAwMDMxMS4zNzJaMASAAgH0oIHUpIHRMIHOMQswCQYDVQQGEwJVUzET
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
# hkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQwLwYJKoZIhvcNAQkEMSIEINZlJLsA8r0W
# IKGWqGp9O9wkKw224Qw++E/TjUsT8F9IMIH6BgsqhkiG9w0BCRACLzGB6jCB5zCB
# 5DCBvQQgLFqNDUOr87rrqVLGRDEieFLEY7UMNnRcWVpB7akcoBMwgZgwgYCkfjB8
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1N
# aWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAVdEB2Lcb+i+KgAAAAAB
# VzAiBCAFt3DtOeMeImHQ2OYucbymc16ATQBx4Pk6fenRiit/PTANBgkqhkiG9w0B
# AQsFAASCAQDTsYE1gqc6qvvj+tcgmBelol8KpFzO7qZVrSVDAqUcebSWeL+HWzPF
# 9wdJF0QsbqO2IPOm/8NJwxjlcoqB3Hz4I+vU3Q/wQJb2rPoNebKyCfs8S8D2Oqzp
# 56FEBvJLmcLIj0XBrKMcFqsNgDXCsqj5fMmC63mUQmjOIZDZv5mnXfNOZVXC8kK7
# wDolPs/GmHc/pTTeCstCI5+J9mQRF9xmnvMR0YsimA79MzMEytQPhtNPwKQyxufy
# DI1UyXmud1O5qJ/39N0gxuBXcra01RKxpHksPxzTw5xVvwy34/hyWhUmEJU7JDOT
# WjPEFoik2QrU0s7MrmI/Msz6LqfH3vSA
# SIG # End signature block
