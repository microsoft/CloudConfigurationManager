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

    $propertiesToSend = @{}
    $dscResourceInfo =
    foreach ($propertyName in $currentInstance.Keys)
    {
        # Retrieve the CIM Instance Property.
        $CimProperty = $currentInstance.$propertyName

        # If the current propertry is a CIMInstance
        if ($CimProperty.Keys -ne $null -and $CimProperty.Keys.Contains("CIMInstance"))
        {
            $cimResult = Expand-CCMCimProperty -CimInstanceValue $currentInstance.$propertyName

            if ($null -eq $cimResult)
            {
                throw "Failed to expand the CIMInstance property [$propertyName] for the resource [$ResourceName]"
            }
            else
            {
                $propertiesToSend.Add($propertyName, $cimResult)
            }
        }
        else
        {
            # Property is not a CIMInstance, therefore add it to the list.
            $propertyValue = $currentInstance.$propertyName

            # If the property contains a variable, check in the received parameters
            # to see if a replacement alternative was specified.
            if (-not [System.String]::IsNullOrEmpty($propertyValue) `
                -and $propertyValue.GetType().Name -eq 'String' `
                -and $propertyValue.Contains('$'))
            {
                foreach ($parameterSpecified in $Parameters.Keys)
                {
                    if ($propertyValue.Contains("`$$parameterSpecified"))
                    {
                        if ($Parameters.$parameterSpecified.GetType().Name -eq 'String')
                        {
                            $propertyValue = $propertyValue.Replace("`$$parameterSpecified", $Parameters.$parameterSpecified)
                        }
                        else
                        {
                            $propertyValue = $Parameters.$parameterSpecified
                        }
                        break
                    }
                }
            }
            elseif ($null -ne $propertyValue -and $propertyValue.GetType().Name -eq 'Object[]')
            {
                $newValue = @()
                foreach ($entry in $propertyValue)
                {
                    $foundParameter = $false
                    foreach ($parameterSpecified in $Parameters.Keys)
                    {
                        if ($null -ne $entry -and $entry.Contains("`$$parameterSpecified"))
                        {
                            $foundParameter = $true
                            if ($Parameters.$parameterSpecified.GetType().Name -eq 'String')
                            {
                                $newValue += $propertyValue.Replace("`$$parameterSpecified", $Parameters.$parameterSpecified)
                            }
                            else
                            {
                                $newValue += $Parameters.$parameterSpecified
                            }
                            break
                        }
                    }
                    if (-not $foundParameter)
                    {
                        $newValue += $entry
                    }
                }
                $propertyValue = $newValue
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

    $cimInstanceProperties = @{}

    if ($CimInstanceValue -notin [System.Array])
    {
        $CimInstanceValue = @($CimInstanceValue)
    }

    $cimPropertyNameBlacklist = @( 'CIMInstance', 'ResourceName')

    $cimResults = @()

    #Iterate over each object within the CimInstanceValueArray
    foreach ($cimInstance in $CimInstanceValue)
    {
        $cimInstanceProperties = @{}
        # this is the current CIM Instance
        foreach ($cimSubPropertyName in $cimInstance.Keys)
        {
            if ($cimSubPropertyName -notin $cimPropertyNameBlacklist)
            {
                $cimSubPropertyValue = $cimInstance.$cimSubPropertyName
                if ($cimSubPropertyValue -isnot [System.Array])
                {
                    $cimSubPropertyValue = @($cimSubPropertyValue)
                }
                foreach ($cimSubPropertyValueItem in $cimSubPropertyValue)
                {
                    if ($cimSubPropertyValueItem -is [System.Collections.Specialized.OrderedDictionary])
                    {
                        $cimSubPropertyValueItem = Expand-CCMCimProperty -CimInstanceValue $cimSubPropertyValueItem
                        if ($cimSubPropertyValueItem.Length -eq 1)
                        {
                            $cimSubPropertyValueItem = [Microsoft.Management.Infrastructure.CimInstance]$cimSubPropertyValueItem[0]
                        }
                    }
                    else
                    {
                        $cimInstanceProperties.Add($cimSubPropertyName, $cimSubPropertyValue[0]) | Out-Null
                    }
                }
            }
        }

        # Scan through the properties of the current CIMInstance to see if there are nested CIMInstances
        $newCimInstanceObject = @{}
        foreach ($topKey in $cimInstanceProperties.Keys)
        {
            if ($cimInstanceProperties.$topKey.GetType().ToString() -eq 'System.Collections.Hashtable')
            {
                $newSubCim = @{}
                foreach ($subKey in $cimInstanceProperties.$topKey.Keys)
                {
                    if ($cimInstanceProperties.$topKey.$subKey.GetType().ToString() -eq 'System.Collections.Hashtable' -and `
                        $cimInstanceProperties.$topKey.$subKey.ContainsKey('CIMInstance'))
                    {
                        $subProperties = ([Hashtable]$cimInstanceProperties.$topKey.$subKey).Clone()
                        $subProperties.Remove('CIMInstance') | Out-Null
                        $subCIM = New-CimInstance -ClassName "$($cimInstanceProperties.$topKey.$subKey.CIMInstance)" `
                                                  -Property $subProperties `
                                                  -ClientOnly
                        $newSubCim.Add($subKey, $subCim)
                    }
                    elseif ($subKey -ne 'CIMInstance')
                    {
                        $newSubCim.Add($subKey, $cimInstanceProperties.$topKey.$subKey)
                    }
                }
                $currentCIMInstance = New-CIMInstance -ClassName $cimInstanceProperties.$topKey.CIMInstance `
                                                      -Property $newSubCim `
                                                      -ClientOnly
                $newCimInstanceObject.Add($topKey, $currentCIMInstance)
            }
            elseif ($topKey -ne 'CIMInstance')
            {
                $newCimInstanceObject.Add($topKey, $cimInstanceProperties.$topKey)
            }
        }

        $cimResults += New-CimInstance -ClassName "$($cimInstance.CIMInstance)" `
            -Property $newCimInstanceObject `
            -ClientOnly
    }

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
        $Content,

        [Parameter()]
        [System.String]
        $SchemaDefinition
    )
    # Convert the DSC Resources into PowerShell Objects
    $resourceInstances = $null
    if (-not [System.String]::IsNullOrEmpty($Path) -and [System.String]::IsNullOrEmpty($Content))
    {
        $Content = Get-Content $Path -Raw
    }
    $resourceInstances = ConvertTo-DSCObject -Content $Content `
                                             -Schema $SchemaDefinition `

    # This will fix an issue with single resource configurations as in this case
    # the return will be a single object. Therefore further processing of the object will fail.
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

        [Parameter(ParameterSetName = 'PreParsed')]
        [Array]
        $ResourceInstances,

        [Parameter()]
        [System.Collections.Hashtable]
        $Parameters,

        [Parameter()]
        [System.String]
        $SchemaDefinition,

        [Parameter()]
        [System.String]
        $ModuleName
    )
    $TestResult = $true
    $Global:CCMAllDrifts = @()

    if ($null -eq $ResourceInstances)
    {
        # Parse the content of the content of the configuration file into an array of PowerShell object.
        $ResourceInstances = Get-CCMParsedResources -Path $Path `
            -SchemaDefinition $SchemaDefinition `
            -Content $Content
    }

    # Loop through all resource instances in the parsed configuration file.
    $i = 1
    $Global:CCMCurrentImportedModule = $null
    foreach ($instance in $resourceInstances)
    {
        $ResourceName = $instance.ResourceName
        $ResourceInstanceName = $instance.ResourceInstanceName

        if ($Global:CCMCurrentImportedModule -ne $ResourceName)
        {
            $ModulePath = (Get-Module $ModuleName -ListAvailable).ModuleBase
            $ResourcePath = Join-Path -Path $ModulePath -ChildPath "/DSCResources/MSFT_$ResourceName/MSFT_$ResourceName.psm1"
            Import-Module $ResourcePath -Force
            $Global:CCMCurrentImportedModule = $ResourceName
        }

        Write-Verbose -Message "[Test-CCMConfiguration]: Resource [$i/$($resourceInstances.Length)]"

        # Retrieve the Hashtable representing the parameters to be sent to the Test method.
        $propertiesToSend = Get-CCMPropertiesToSend -Instance $instance `
            -Parameters $Parameters

        # Remove DSC specific properties
        $propertiesToSend.Remove('DependsOn') | Out-Null
        $propertiesToSend.Remove('PSDSCRunAsCredential') | Out-Null

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
        $Parameters,

        [Parameter()]
        [System.String]
        $SchemaDefinition,

        [Parameter()]
        [System.String]
        $ModuleName
    )

    # Parse the content of the content of the configuration file into an array of PowerShell object.
    $resourceInstances = Get-CCMParsedResources -Path $Path `
        -SchemaDefinition $SchemaDefinition `
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
