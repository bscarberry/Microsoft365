# This will install all dependencies for Microsoft365DSC module in Azure Automation Account.
# The module istelf will not run until these have been installed / updated wit this script.
# This is based of of M365 Oh Eh's script: https://o365eh.com/2020/10/27/episode-74-using-microsoft-dsc-as-a-runbook-in-azure-automation/
# To run, the Azure modules: Az.Accounts, Az.Automation must be installed
# Brandon Scarberry
# 01/08/2025

# Tenant and Azure subscription info
$tenantID = "87d7f7c6-46b3-4180-9324-be9ef2d9386c"
$subscriptionID = "b7fe5b06-d5a2-4e45-b4f4-ca6b2ee2fd4e"
$automationAccount = "autoTwit"
$resourceGroup = "Automation-rg"
 
$moduleName = "Microsoft365dsc"

Connect-AzAccount -SubscriptionId $subscriptionID -Tenant $tenantID

Function Get-Dependency {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ModuleName   
    )
 
    Install-Module $ModuleName -Force -AllowClobber
    $local = Get-Module Microsoft365Dsc -ListAvailable | Sort-Object Version -Descending
    $ModuleVersion = $local[0].Version

    $ModulePath = $local[0].Path
    $currentPath = $ModulePath.Substring(0, $ModulePath.IndexOf("Microsoft365DSC.psd1"))
    
    # get dependencies from manifest file
    $manifest = Import-PowerShellDataFile "$currentPath/Dependencies/Manifest.psd1"
    $dependencies = $manifest.Dependencies

    $OrderedModules = [System.Collections.ArrayList]@()
     
    $ModuleObject = [PSCustomObject]@{
        ModuleName    = $ModuleName
        ModuleVersion = $ModuleVersion
    }
     
    # If no dependencies are found, only the module is added to the list
    if (![string]::IsNullOrEmpty($dependencies) ) {
        foreach ($dependency in $dependencies){
            $DepenencyObject = [PSCustomObject]@{
                ModuleName    = $($dependency.ModuleName)
                ModuleVersion = $($dependency.RequiredVersion)
            }
            $OrderedModules.Add($DepenencyObject) | Out-Null
        }
    }
 
    $OrderedModules.Add($ModuleObject) | Out-Null
 
    return $OrderedModules
}
 
$ModulesAndDependencies = Get-Dependency -moduleName $moduleName
# Write-Host $ModulesAndDependencies
 
write-output "Installing $($ModulesAndDependencies | ConvertTo-Json)"
 
#Install Module and Dependencies into Automation Account
foreach($module in $ModulesAndDependencies){
    $CheckInstalled = get-AzAutomationModule -AutomationAccountName $automationAccount -ResourceGroupName $resourceGroup -Name $($module.modulename) -ErrorAction SilentlyContinue
    if($CheckInstalled.ProvisioningState -eq "Succeeded" -and $CheckInstalled.Version -ge $module.ModuleVersion){
        write-output "$($module.modulename) existing: v$($CheckInstalled.Version), required: v$($module.moduleVersion)"
    }
    else{
        New-AzAutomationModule -AutomationAccountName $automationAccount -ResourceGroupName $resourceGroup -Name $($module.modulename) -ContentLinkUri "https://www.powershellgallery.com/api/v2/package/$($module.modulename)/$($module.moduleVersion)" -Verbose    
        While($(get-AzAutomationModule -AutomationAccountName $automationAccount -ResourceGroupName $resourceGroup -Name $($module.modulename)).ProvisioningState -eq 'Creating'){
            Write-output "Importing $($module.modulename)..."
            start-sleep -Seconds 10
        }
    }
}
Disconnect-AzAccount
