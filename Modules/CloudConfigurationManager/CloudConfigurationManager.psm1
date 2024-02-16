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
    $currentInstance = ([System.Collections.Hashtable]$instance).Clone()

    $ResourceName = $currentInstance.ResourceName
    $currentInstance.Remove('ResourceName') | Out-Null

    $ResourceInstanceName = $currentInstance.ResourceInstanceName
    $currentInstance.Remove('ResourceInstanceName') | Out-Null

    # Retrieve information about the DSC resource
    $dscResourceInfo = Get-DSCResource -Name $ResourceName

    $propertiesToSend = @{}
    foreach ($propertyName in $currentInstance.Keys)
    {
        # Retrieve the CIM Instance Property.
        $CimProperty = $dscResourceInfo.Properties | Where-Object -FilterScript {$_.Name -eq $propertyName}

        # If the current propertry is a CIMInstance
        if ($CimProperty.PropertyType.StartsWith('[MSFT_'))
        {
            $cimResult = @()

            # Loop through all CIMInstances in the property
            foreach ($cimEntry in $currentInstance.$propertyName)
            {
                $cimInstanceProperties = @{}

                # Loop through all properties of the CIMInstance
                foreach ($cimSubPropertyName in $cimEntry.Keys)
                {
                    if ($cimSubPropertyName -ne 'CIMInstance')
                    {
                        $cimInstanceProperties.Add($cimSubPropertyName, $cimEntry.$cimSubPropertyName)
                    }
                }

                $CimInstanceName = ([Array]$currentInstance.$propertyName.CIMInstance)[0]
                $propertyCIMInstanceValue = New-CimInstance -ClassName $CimInstanceName `
                                                            -Property $cimInstanceProperties `
                                                            -ClientOnly
                $cimResult += $propertyCIMInstanceValue
            }
            $propertiesToSend.Add($propertyName, [Microsoft.Management.Infrastructure.CimInstance[]]$cimResult)
        }
        else
        {
            # Property is not a CIMInstance, therefore add it to the list.
            $propertyValue = $currentInstance.$propertyName

            # If the property's value is a variable, try to retrieve its value from the list of
            # parameters provided by the user.
            if ($propertyValue.StartsWith('$'))
            {
                $propertyVariableName = $propertyValue.Substring(1)
                $propertyValue = $Parameters.$propertyVariableName
            }

            # If the property is an empty array, explicitely define it as empty instead of null.
            if ([System.String]::IsNullOrEmpty($propertyValue) -and $CimProperty.PropertyType.EndsWith('[]]'))
            {
                $propertyValue = @('')
            }
            $propertiesToSend.Add($propertyName, $propertyValue)
        }
    }
    return $propertiesToSend
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
    return $resourceInstances
}

function Test-CCMConfiguration
{
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param(
        [Parameter(Mandatory = $true)]
        [System.String]
        $ModuleName,

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

    $currentInstance = $null
    $resourceInstances = Get-CCMParsedResources -Path $Path `
                                                -Content $Content
    foreach ($instance in $resourceInstances)
    {
        $ResourceName = $instance.ResourceName
        $ResourceInstanceName = $instance.ResourceInstanceName

        $propertiesToSend = Get-CCMPropertiesToSend -Instance $instance `
                                                    -Parameters $Parameters
        # Load the resource's module.
        if ($resourceName -ne $currentLoadedModule)
        {            
            $ResourceInfo = Get-DSCResource -Name $ResourceName
            Import-Module $ResourceInfo.Path -Force
            $currentLoadedModule = $resourceName
        }
        
        # Evaluate the properties of the current resource.
        $currentResult = Test-TargetResource @propertiesToSend

        # If a drift was detected, augment its related info with the name of the
        # current instance and collect it in the CCMAllDrifts Global Variable.
        if (-not $currentResult)
        {
            $TestResult = $false
            $currentDrift = $Global:M365DSCCurrentDriftInfo
            $currentDrift.Add('InstanceName', $ResourceInstanceName)
            $Global:CCMAllDrifts += $currentDrift
        }
    }
    return $TestResult
}
