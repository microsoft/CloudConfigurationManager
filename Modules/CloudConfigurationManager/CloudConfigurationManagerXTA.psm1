function Test-CCMConfigurationXTA
{
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param(
        [Parameter()]
        [System.String]
        $Content,

        [Parameter()]
        [System.String]
        $SchemaDefinition,

        [Parameter()]
        [System.String]
        $ModuleName = 'Microsoft365DSC',

        [Parameter()]
        [PScredential]
        $Credential

    )
    $noDrifts = $true
    # Convert the XTA configuration to a JSON Object.
    $configuration = ConvertFrom-Json $Content

    # Convert the XTA configuration to a JSON Object.    
    if ($Global:CCMSchemaDefinition -eq $null)
    {
        $Global:CCMSchemaDefinition = ConvertFrom-Json $SchemaDefinition
    }

    # Load the Mapping file that will help convert the Namespaces into DSC Resources Names.
    # E.g, /Microsoft/Entra/Application == AADApplication
    if ($Global:CCMMappings -eq $null)
    {
        $mappingPath = Join-Path -Path $PSScriptRoot -ChildPath 'XTAtoDSCMappings.psd1' -Resolve
        $Global:CCMMappings = Import-PowerShellDataFile -Path $mappingPath
    }

    # Loop through all resources defined in the XTA Configuration
    foreach ($resource in $configuration.resources)
    {
        # Get the associated DSC Resource name associated with the provided namespace
        # from the loaded Mappings file.
        $resourceType = $resource.Type
        $ResourceName = $Global:CCMMappings.$resourceType

        # Load the current DSC Resource module (.psm1) in order to get access to its
        # Get/Set/Test methods. Skip reloading the module if its already in memory.
        if ($Global:CCMCurrentImportedModule -ne $ResourceName)
        {
            $ModulePath = (Get-Module $ModuleName -ListAvailable).ModuleBase
            $ResourcePath = Join-Path -Path $ModulePath -ChildPath "/DSCResources/MSFT_$ResourceName/MSFT_$ResourceName.psm1"
            Import-Module $ResourcePath -Force
            $Global:CCMCurrentImportedModule = $ResourceName
        }

        # Convert the 'properties' section of the XTA JSON configuration into a
        # hashtable of parameters that the DSC resource will accept.
        $parameters = Get-CCMPropertiesFromXTABlock -PropertyBlock $resource.properties `
                                      -SchemaDefinition $SchemaDefinition `
                                      -InstanceType $resource.Type

        # Call the Test-TargetResource of the current resource with the formated
        # parameters.
        $TestResult = Test-TargetResource @parameters -Credential $Credential
        if (-not $TestResult)
        {
            $noDrifts = $false
        }
    }

    #region Cleanup Global Variables
    $Global:CCMCurrentImportedModule = $null
    $Global:CCMSchemaDefinition      = $null
    $Global:CCMMappings              = $null
    #endregion

    return $noDrifts
}

function Get-CCMPropertiesFromXTABlock
{
    [CmdletBinding()]
    [OutputType([Object])]
    param(
        [Parameter()]
        [System.String]
        $InstanceType,

        [Parameter()]
        [PSCustomObject]
        $PropertyBlock,

        [Parameter()]
        [System.String]
        $SchemaDefinition,

        [Parameter()]
        [Switch]
        $IsCIMInstance
    )

    # If the current block is a CIMInstance, that instantiate a new CIM Object
    # of the required type. Otherwise, simply instantiate a new Hashtable.
    if ($IsCIMInstance.IsPresent)
    {
        $result = [Microsoft.Management.Infrastructure.CimInstance]::new($InstanceType)
    }
    else
    {
        $result = @{}
    }
    #endregion

    # Retrieve the current resource or CIMInstance definition to get information
    # about its properties and their associated variable types (e.g. Int, string, CIMInstance, etc.)
    $mappedDSCResourceName = $Global:CCMMappings.$InstanceType
    if ($null -eq $mappedDSCResourceName)
    {
        if ($InstanceType.StartsWith('MSFT_'))
        {
            $className = $InstanceType
        }
        else
        {
            $className = 'MSFT_' + $InstanceType
        }
    }
    else
    {
        $className = 'MSFT_' + $mappedDSCResourceName
    }

    # Get information about the current resource/CIMInstance schema from the provided schema definition
    $instanceTypeDefinition = $Global:CCMSchemaDefinition | Where-Object -FilterScript {$_.ClassName -eq $className}
    
    # Loop through all the properties of the current instance.
    $keys = Get-Member -InputObject $PropertyBlock -MemberType NoteProperty
    foreach ($key in $keys.Name)
    {
        # Retrieve the property's information from the schema definition to help us determine its data type.
        $propertyDefinition = $instanceTypeDefinition.Parameters | Where-Object -FilterScript {$_.Name -eq $key}

        # Case - Current property's value is a nested CIMInstance (or an array of CIMInstances).
        if ($propertyDefinition.CIMType.StartsWith('MSFT_'))
        {
            $ResourceType = $propertyDefinition.CIMType.Replace('[]', '')
            $value = @()

            # Loop through each instance of the current property block and recursively
            # call back the current method for each CIMInstance.
            foreach ($currentBlock in $PropertyBlock.$key)
            {
                $value += Get-CCMPropertiesFromXTABlock -PropertyBlock $currentBlock `
                                                        -InstanceType $ResourceType `
                                                        -IsCIMInstance
            }
            if ($result.GetType().Name -eq 'CIMInstance')
            {
                if ($value.GetType().Name -eq 'Object[]')
                {
                    $cimProperty = [Microsoft.Management.Infrastructure.CIMProperty]::Create($key, [CIMInstance[]]$value, 'Property')
                }
                else
                {
                    $cimProperty = [Microsoft.Management.Infrastructure.CIMProperty]::Create($key, [CIMInstance]$value, 'Property')
                }
                $result.CimInstanceProperties.Add($cimProperty) | Out-Null
            }
            else
            {
                $result.Add($key, $value)
            }
        }
        else
        {
            $value = $PropertyBlock.$key

            # If the current property is not of type string, use code invocation to dynamically cast
            # the property's value with the appropriate type, as defined by the provided schema definition.
            if ($propertyDefinition.CIMType -ne 'string')
            {
                $scriptBlock = @"
                                        `$typeStaticMethods = [$($propertyDefinition.CIMType)] | gm -static
                                        if (`$typeStaticMethods.Name.Contains('TryParse'))
                                        {
                                            [$($propertyDefinition.CIMType)]::TryParse(`$value, [ref]`$value) | Out-Null
                                        }
"@
            }

            # If the current property is a CIMInstance, add its properties to the CIMInstance created
            # previously at the beginning of the current method. Otherwise, simply add the key/value pair
            # to the hashtable.
            if ($IsCIMInstance.IsPresent)
            {
                $cimProperty = [Microsoft.Management.Infrastructure.CIMProperty]::Create($key, $value, 'Property')
                $result.CimInstanceProperties.Add($cimProperty) | Out-Null
            }
            else
            {
                $result.Add($key, $value)
            }
        }
    }

    return $result
}