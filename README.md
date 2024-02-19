# Cloud Configuration Manager (CCM)

The Cloud Configuration Manager (CCM) is a serverless alternative to the PowerShell Desired State Configuration (DSC) engine known as the Local Configuration Manager (LCM). It is meant to be supported Cross-Platform (Linux and Windows) and to have a very lightweight footprint. It allows administrators to call into either the Test-CCMConfiguration to evaluate a configuration file against an environment for drifts, or to apply a configuration baseline by calling into the Start-CCMConfiguration cmdlet.

## Arguments

Both the Start-CCMConfiguration and Test-CCMConfiguration cmdlets accept the same parameter set.

### Path

Represents the location of the .ps1 configuration file to either evaluate or deploy.

### Content

As an alternative to providing a path to a file, it is possible to pass in the content of the configuration baseline to the cmdlets directly.

### Parameters

A Hashtable to represents the list of variables defined within the configuration to replace with the specified value.

## Example

```powershell
$creds = Get-Credential
Start-CCMConfiguration -Path 'C:\dsc\M365TenantConfig.ps1' `
    -Parameters @{
    Credscredential = $creds
}
```
