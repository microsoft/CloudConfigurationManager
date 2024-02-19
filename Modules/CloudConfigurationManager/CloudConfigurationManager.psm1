function Get-CCMPropertiesToSend
{
    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Hashtable]
        $Instance,

        [Parameter()]
        [System.Collections.Hashtable]
        $Parameters
    )

    # Clone the instance to avoid modifying the original object.
    $currentInstance = ([System.Collections.Hashtable]$instance).Clone()

    $ResourceName = $currentInstance.ResourceName
    $currentInstance.Remove('ResourceName') | Out-Null

    $ResourceInstanceName = $currentInstance.ResourceInstanceName
    $currentInstance.Remove('ResourceInstanceName') | Out-Null

    Write-Verbose -Message "[Get-CCMPropertiesToSend]: Calling Get-CCMPropertiesToSend for {$ResourceInstanceName}"

    # Retrieve information about the DSC resource
    $dscResourceInfo = Get-DscResource -Name $ResourceName

    $propertiesToSend = @{}
    foreach ($propertyName in $currentInstance.Keys)
    {
        # Retrieve the CIM Instance Property.
        $CimProperty = $dscResourceInfo.Properties | Where-Object -FilterScript { $_.Name -eq $propertyName }

        # If the current propertry is a CIMInstance
        if ($CimProperty.PropertyType.StartsWith('[MSFT_'))
        {

            $cimResult = Expand-CCMCimProperty -CimInstanceValue $currentInstance.$propertyName

            if ($null -eq $cimResult)
            {
                throw "Failed to expand the CIMInstance property [$propertyName] for the resource [$ResourceName]"
            }
            else
            {
                $propertiesToSend.Add($propertyName, [Microsoft.Management.Infrastructure.CimInstance[]]$cimResult)
            }
        }
        else
        {
            # Property is not a CIMInstance, therefore add it to the list.
            $propertyValue = $currentInstance.$propertyName

            # If the property's value is a variable, try to retrieve its value from the list of
            # parameters provided by the user.
            if ($propertyValue.ToString().StartsWith('$'))
            {
                $propertyVariableName = $propertyValue.Substring(1)
                $propertyValue = $Parameters.$propertyVariableName
            }

            $propertiesToSend.Add($propertyName, $propertyValue)
        }
    }
    return $propertiesToSend
}

function Expand-CCMCimProperty
{

    [CmdletBinding()]
    [OutputType([Microsoft.Management.Infrastructure.CimInstance[]])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Object]
        $CimInstanceValue
    )

    # If the property is not an array, convert it to an array for further processing.
    # This is necessary as the property can be a single value or an array of values.
    if ($CimInstanceValue -notin [System.Array])
    {
        $CimInstanceValue = @($CimInstanceValue)
    }

    # Blacklist of properties that should not be included in the final result.
    $cimPropertyNameBlacklist = @('CIMInstance', 'ResourceName')

    $cimResults = @()

    #Iterate over each object within the CimInstanceValueArray
    foreach ($cimInstance in $CimInstanceValue)
    {
        $cimInstanceProperties = @{}

        foreach ($cimSubPropertyName in $cimInstance.Keys)
        {
            # If the property is not in the blacklist, add it to the property table.
            if ($cimSubPropertyName -notin $cimPropertyNameBlacklist)
            {
                # Retrieve the property value
                $cimSubPropertyValue = $cimInstance.$cimSubPropertyName

                # If the property is not an array, convert it to an array for further processing.
                # This is necessary as the property can be a single value or an array of values.
                if ($cimSubPropertyValue -isnot [System.Array])
                {
                    $cimSubPropertyValue = @($cimSubPropertyValue)
                }

                # Iterate over each value within the property array
                foreach ($cimSubPropertyValueItem in $cimSubPropertyValue)
                {
                    # If the value is a CIMInstance, expand it.
                    if ($cimSubPropertyValueItem -is [System.Collections.Specialized.OrderedDictionary])
                    {
                        # Recursively expand the CIMInstance
                        $cimSubPropertyValueItem = Expand-CCMCimProperty -CimInstanceValue $cimSubPropertyValueItem
                    }
                    else
                    {
                        # Add the value to the property table
                        $cimInstanceProperties.Add($cimSubPropertyName, $cimSubPropertyValue[0]) | Out-Null
                    }
                }
            }
        }

        # Create a new CIMInstance with the expanded properties
        $cimResults += New-CimInstance -ClassName "$($cimInstance.CIMInstance)" `
            -Property $cimInstanceProperties `
            -ClientOnly
    }

    # Return the expanded CIMInstances
    return [Microsoft.Management.Infrastructure.CimInstance[]]$cimResults
}

function Get-CCMParsedResources
{
    [CmdletBinding()]
    [OutputType([Array])]
    param(
        [Parameter()]
        [System.String]
        $Path,

        [Parameter()]
        [System.String]
        $Content
    )
    # Convert the DSC Resources into PowerShell Objects
    $resourceInstances = $null
    if (-not [System.String]::IsNullOrEmpty($Path))
    {
        $resourceInstances = ConvertTo-DSCObject -Path $path
    }
    elseif (-not [System.String]::IsNullOrEmpty($Content))
    {
        $resourceInstances = ConvertTo-DSCObject -Content $Content
    }

    # This will fix an issue with single resource configurations as in this case
    # the return will be a single object. Therfore further processing of the object will fail.
    if ($resourceInstances -isnot [System.Array])
    {
        $resourceInstances = @($resourceInstances)
    }

    return $resourceInstances
}

function Test-CCMConfiguration
{
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param(
        [Parameter(ParameterSetName = 'Path')]
        [System.String]
        $Path,

        [Parameter(ParameterSetName = 'Content')]
        [System.String]
        $Content,

        [Parameter()]
        [System.Collections.Hashtable]
        $Parameters
    )
    $TestResult = $true
    $Global:CCMAllDrifts = @()
    $currentLoadedModule = ''

    # Parse the content of the content of the configuration file into an array of PowerShell object.
    $resourceInstances = Get-CCMParsedResources -Path $Path `
        -Content $Content

    # Loop through all resource instances in the parsed configuration file.
    $i = 1
    foreach ($instance in $resourceInstances)
    {
        $ResourceName = $instance.ResourceName
        $ResourceInstanceName = $instance.ResourceInstanceName

        Write-Verbose -Message "[Test-CCMConfiguration]: Resource [$i/$($resourceInstances.Length)]"

        # Retrieve the Hashtable representing the parameters to be sent to the Test method.
        $propertiesToSend = Get-CCMPropertiesToSend -Instance $instance `
            -Parameters $Parameters
        # Load the resource's module.
        if ($ResourceName -ne $currentLoadedModule)
        {
            $ResourceInfo = Get-DscResource -Name $ResourceName
            Import-Module $ResourceInfo.Path -Force -Verbose:$false
            $currentLoadedModule = $ResourceName
        }

        # Evaluate the properties of the current resource.
        Write-Verbose -Message "[Test-CCMConfiguration]: Calling Test-TargetResource for {$ResourceInstanceName}"
        $currentResult = Test-TargetResource @propertiesToSend
        Write-Verbose -Message "[Test-CCMConfiguration]: Test-TargetResource for {$ResourceInstanceName} returned {$currentResult}"

        # If a drift was detected, augment its related info with the name of the
        # current instance and collect it in the CCMAllDrifts Global Variable.
        if (-not $currentResult)
        {
            $TestResult = $false

            # If the the current resource's module implements the CCM Drift pattern, collect
            # and enrich the information related to the drift from the CCMCurrentDriftInfo Global variable.
            # This variable needs to be populated from the resource's module.
            if ($null -ne $Global:CCMCurrentDriftInfo)
            {
                $currentDrift = $Global:CCMCurrentDriftInfo
                $currentDrift.Add('InstanceName', $ResourceInstanceName)
                $Global:CCMAllDrifts += $currentDrift
            }
        }
        $i++
    }
    Write-Verbose -Message "[Test-CCMConfiguration]: Returned {$TestResult}"
    return $TestResult
}

function Start-CCMConfiguration
{
    [CmdletBinding()]
    param(
        [Parameter(ParameterSetName = 'Path')]
        [System.String]
        $Path,

        [Parameter(ParameterSetName = 'Content')]
        [System.String]
        $Content,

        [Parameter()]
        [System.Collections.Hashtable]
        $Parameters
    )
    $currentLoadedModule = ''

    # Parse the content of the content of the configuration file into an array of PowerShell object.
    $resourceInstances = Get-CCMParsedResources -Path $Path `
        -Content $Content

    # Loop through all resource instances in the parsed configuration file.
    $i = 1
    foreach ($instance in $resourceInstances)
    {
        $ResourceName = $instance.ResourceName
        $ResourceInstanceName = $instance.ResourceInstanceName

        Write-Verbose -Message "[Start-CCMConfiguration]: Resource [$i/$($resourceInstances.Length)]"

        # Retrieve the Hashtable representing the parameters to be sent to the Test method.
        $propertiesToSend = Get-CCMPropertiesToSend -Instance $instance `
            -Parameters $Parameters

        # Load the resource's module.
        if ($ResourceName -ne $currentLoadedModule)
        {
            $ResourceInfo = Get-DscResource -Name $ResourceName
            Import-Module $ResourceInfo.Path -Force -Verbose:$false
            $currentLoadedModule = $ResourceName
        }

        # Evaluate the properties of the current resource.
        Write-Verbose -Message "[Start-CCMConfiguration]: Calling Test-TargetResource for {$ResourceInstanceName}"
        $currentResult = Test-TargetResource @propertiesToSend
        Write-Verbose -Message "[Start-CCMConfiguration]: Test-TargetResource for {$ResourceInstanceName} returned {$currentResult}"

        # If a drift was detected, apply the defined configuration for the resource instance by
        # calling into the Set-TargetResource method of the resource.
        if (-not $currentResult)
        {
            Write-Verbose -Message "[Start-CCMConfiguration]: Calling Set-TargetResource for {$ResourceInstanceName}"
            Set-TargetResource @propertiesToSend
            Write-Verbose -Message "[Start-CCMConfiguration]: Configuration applied successfully for {$ResourceInstanceName}"
        }
        $i++
    }
}
