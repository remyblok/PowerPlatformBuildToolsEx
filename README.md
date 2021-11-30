# Power Platform Build Tools Extensions
Extensions on the Power Platform Build Tools for Azure DevOps Pipelines
## Overview
Microsoft delivers the Power Platform Build Tools to automate common build and deployment tasks related to the Power Platform. Learn more about the Build Tools provided by Microsoft here [here](https://aka.ms/buildtoolsdoc).

The Tools in this extension build upon that basis and add new tools that can be used during your build and deployment pipeline.
## Helper Tasks
The available helper tasks are described below.

### Get Connection String
You can create Service Connections to the Power Platform Environment using the default functionality in DevOps. This task creates a [Dataverse connection string](https://docs.microsoft.com/en-us/powerapps/developer/data-platform/xrm-tooling/use-connection-strings-xrm-tooling-connect) to the Environment based on the provided Service Connection and stores it in a pipeline variable. The variable name that is used is specified in the inputs of the task.

The Task supports both SPN and generic credentials. For generic credentials it creates a connection string with OAuth as authentication type. It uses the default AppId and RedirectUri as specified in the Microsoft Docs, if non are given.

The variable can be used in subsequent steps in order to connect to the Dataverse environment. For example when using the [Microsoft.Xrm.Data.PowerShell-module](https://github.com/seanmcne/Microsoft.Xrm.Data.PowerShell) in a PowerShell step.

#### YAML snippet (Get Connection String)
```yml
# Get Connection string for the provided Service connection
- task: PowerPlatformGetConnectionString@0
  displayName: 'Get Connection string'
  inputs:
    authenticationType: 'PowerPlatformSPN'
    PowerPlatformSPN: 'My service connection'
    OutputVariableName: 'envConnectionString'
```

```yml
# Get Connection string for the provided Service connection
- task: PowerPlatformGetConnectionString@0
  displayName: 'Get Connection string'
  inputs:
    # Username/password (no MFA support)
    PowerPlatformEnvironment: 'My service connection'
    OutputVariableName: 'envConnectionString'
```

#### Parameters (Get Connection String)

| Parameters    | Description   |
|---------------|---------------|
| `authenticationType`<br/>Type of authentication | (Optional) Specify either **PowerPlatformEnvironment** for a username/password connection or **PowerPlatformSPN** for a Service Principal/client secret connection. More information: see `BuildTools.EnvironmentUrl` under [Power Platform Create Environment](#power-platform-create-environment) |
| `PowerPlatformEnvironment`<br/>Power Platform environment URL | The service endpoint for the environment to connect to. Defined under **Service Connections** in **Project Settings**. |
| `PowerPlatformSPN`<br/>Power Platform Service Principal | The service endpoint for the environment to connect to. Defined under **Service Connections** in **Project Settings**. |
| `OutputVariableName`<br/>Name of the output variable | Name of the variable that will be used to output the connection string to. The variable will be marked as a secret to prevent leaking information. |
| `AppId`<br/>Application ID as registered in the Azure Active Directory | (Optional) Define the App ID to use for OAuth login. The App need to be defined in the Azure Active Directory |
| `RedirectUri`<br/>Uri as defined for the specified App | (Optional) Define the Redirect URI of the App. The Uri should match the Uri as it is defined in the App registration in the Azure Active Directory |