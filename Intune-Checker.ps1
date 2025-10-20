# Checks all Intune assignments for a specific group and exports the results to a CSV file.
# Includes policies, apps, configurations, security configurations and policies.

<#
.SYNOPSIS
    Check all Intune assignments for a specific group.

.DESCRIPTION
    This script collects all Intune assignments (policies, apps, configurations) for a specific group
    and exports them to a CSV file.

.PARAMETER GroupIdentifier
    Group name or Object ID to check assignments for.

.PARAMETER ExportPath
    Path for the exported CSV file.

.EXAMPLE
    .\IntuneAssignmentChecker.ps1 -GroupIdentifier "IT-Admins" -ExportPath "C:\Reports\Assignments.csv"

.EXAMPLE
    .\IntuneAssignmentChecker.ps1 -GroupIdentifier "12345678-1234-1234-1234-123456789012"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$GroupIdentifier,

    [Parameter(Mandatory = $false)]
    [string]$ExportPath
)

$script:GraphEndpoint = "https://graph.microsoft.com"
$script:AllAssignments = [System.Collections.ArrayList]::new()
$script:GroupId = $null
$script:GroupName = $null
$script:FinalExportPath = $null

function Connect-MgGraphWithAuth {
    $requiredScopes = @(
        "Group.Read.All",
        "DeviceManagementApps.Read.All",
        "DeviceManagementConfiguration.Read.All",
        "DeviceManagementManagedDevices.Read.All"
    )
    
    try {
        Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
        Connect-MgGraph -Scopes $requiredScopes -NoWelcome
        Write-Host "Successfully connected to Microsoft Graph" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Error "Failed to connect to Microsoft Graph: $_"
        return $false
    }
}

function Invoke-GraphRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        
        [Parameter(Mandatory = $false)]
        [string]$Method = "GET"
    )
    
    try {
        return Invoke-MgGraphRequest -Uri $Uri -Method $Method
    }
    catch {
        Write-Warning "Graph API request failed for $Uri : $_"
        return $null
    }
}

function Get-GraphEntityWithPaging {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )
    
    $allItems = [System.Collections.ArrayList]::new()
    $currentUri = $Uri
    
    do {
        $response = Invoke-GraphRequest -Uri $currentUri
        if ($response -and $response.value) {
            [void]$allItems.AddRange($response.value)
        }
        $currentUri = $response.'@odata.nextLink'
    } while ($currentUri)
    
    return $allItems
}

function Resolve-Group {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Identifier
    )
    
    # Check if it's a GUID
    if ($Identifier -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
        $uri = "$script:GraphEndpoint/v1.0/groups/$Identifier"
        $group = Invoke-GraphRequest -Uri $uri
        
        if ($group) {
            $script:GroupId = $group.id
            $script:GroupName = $group.displayName
            return $true
        }
        else {
            Write-Error "No group found with ID: $Identifier"
            return $false
        }
    }
    else {
        # Search by display name
        $uri = "$script:GraphEndpoint/v1.0/groups?`$filter=displayName eq '$Identifier'"
        $response = Invoke-GraphRequest -Uri $uri
        
        if (-not $response.value -or $response.value.Count -eq 0) {
            Write-Error "No group found with name: $Identifier"
            return $false
        }
        elseif ($response.value.Count -gt 1) {
            Write-Error "Multiple groups found with name: $Identifier. Please use Object ID instead:"
            foreach ($group in $response.value) {
                Write-Host "  - $($group.displayName) (ID: $($group.id))" -ForegroundColor Yellow
            }
            return $false
        }
        
        $script:GroupId = $response.value[0].id
        $script:GroupName = $response.value[0].displayName
        return $true
    }
}

function Initialize-ExportPath {
    if (-not $ExportPath) {
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $safeName = $script:GroupName -replace '[\\/:*?"<>|]', '_'
        $script:FinalExportPath = Join-Path $PWD "GroupAssignments_${safeName}_$timestamp.csv"
    }
    else {
        $script:FinalExportPath = $ExportPath
    }
}

function Get-EntityAssignments {
    param(
        [Parameter(Mandatory = $true)]
        [string]$EntityType,
        
        [Parameter(Mandatory = $true)]
        [string]$EntityId
    )
    
    $assignmentsUri = switch -Regex ($EntityType) {
        'managedAppPolicies' {
            $policyUri = "$script:GraphEndpoint/beta/deviceAppManagement/managedAppPolicies/$EntityId"
            $policy = Invoke-GraphRequest -Uri $policyUri
            
            if ($policy) {
                switch ($policy.'@odata.type') {
                    '#microsoft.graph.androidManagedAppProtection' {
                        "$script:GraphEndpoint/beta/deviceAppManagement/androidManagedAppProtections('$EntityId')/assignments"
                    }
                    '#microsoft.graph.iosManagedAppProtection' {
                        "$script:GraphEndpoint/beta/deviceAppManagement/iosManagedAppProtections('$EntityId')/assignments"
                    }
                    '#microsoft.graph.windowsManagedAppProtection' {
                        "$script:GraphEndpoint/beta/deviceAppManagement/windowsManagedAppProtections('$EntityId')/assignments"
                    }
                    default { $null }
                }
            }
        }
        'mobileAppConfigurations' {
            "$script:GraphEndpoint/beta/deviceAppManagement/mobileAppConfigurations('$EntityId')/assignments"
        }
        'mobileApps' {
            "$script:GraphEndpoint/beta/deviceAppManagement/mobileApps('$EntityId')/assignments"
        }
        default {
            "$script:GraphEndpoint/beta/deviceManagement/$EntityType('$EntityId')/assignments"
        }
    }
    
    if (-not $assignmentsUri) {
        return @()
    }
    
    $assignments = Get-GraphEntityWithPaging -Uri $assignmentsUri
    
    # Filter for our specific group
    $groupAssignments = $assignments | Where-Object {
        $_.target.groupId -eq $script:GroupId
    }
    
    $processedAssignments = foreach ($assignment in $groupAssignments) {
        $targetType = $assignment.target.'@odata.type'
        
        [PSCustomObject]@{
            IsExclusion = ($targetType -eq '#microsoft.graph.exclusionGroupAssignmentTarget')
            Intent = $assignment.intent
        }
    }
    
    return $processedAssignments
}

function Get-PolicyPlatform {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Policy
    )
    
    $odataType = $Policy.'@odata.type'
    
    if (-not $odataType) { return "Unknown" }
    
    switch -Regex ($odataType) {
        "android" {
            if ($odataType -like "*WorkProfile*") { return "Android Work Profile" }
            elseif ($odataType -like "*DeviceOwner*") { return "Android Enterprise" }
            else { return "Android" }
        }
        "ios|iPad" { return "iOS/iPadOS" }
        "macOS" { return "macOS" }
        "windows" { return "Windows" }
        default {
            if ($Policy.platforms) { return ($Policy.platforms -join ", ") }
            return "Multi-Platform"
        }
    }
}

function Add-AssignmentRecord {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Category,
        
        [Parameter(Mandatory = $true)]
        [string]$PolicyName,
        
        [Parameter(Mandatory = $true)]
        [string]$PolicyId,
        
        [Parameter(Mandatory = $false)]
        [string]$Platform = "N/A",
        
        [Parameter(Mandatory = $false)]
        [bool]$IsExclusion = $false,
        
        [Parameter(Mandatory = $false)]
        [string]$Intent = "N/A"
    )
    
    [void]$script:AllAssignments.Add([PSCustomObject]@{
        GroupName = $script:GroupName
        GroupId = $script:GroupId
        Category = $Category
        PolicyName = $PolicyName
        PolicyId = $PolicyId
        Platform = $Platform
        AssignmentType = if ($IsExclusion) { "Excluded" } else { "Included" }
        Intent = $Intent
        CollectedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    })
}

function Get-DeviceConfigurations {
    Write-Host "Checking Device Configurations..." -ForegroundColor Yellow
    
    $uri = "$script:GraphEndpoint/beta/deviceManagement/deviceConfigurations"
    $configs = Get-GraphEntityWithPaging -Uri $uri
    
    $total = $configs.Count
    $current = 0
    $found = 0
    
    foreach ($config in $configs) {
        $current++
        Write-Progress -Activity "Device Configurations" -Status "$current of $total" -PercentComplete (($current / $total) * 100)
        
        $assignments = Get-EntityAssignments -EntityType "deviceConfigurations" -EntityId $config.id
        
        foreach ($assignment in $assignments) {
            $found++
            Add-AssignmentRecord -Category "Device Configuration" `
                                -PolicyName $config.displayName `
                                -PolicyId $config.id `
                                -Platform (Get-PolicyPlatform -Policy $config) `
                                -IsExclusion $assignment.IsExclusion
        }
    }
    
    Write-Host "  Found $found assignments" -ForegroundColor Green
}

function Get-SettingsCatalog {
    Write-Host "Checking Settings Catalog Policies..." -ForegroundColor Yellow
    
    $uri = "$script:GraphEndpoint/beta/deviceManagement/configurationPolicies"
    $policies = Get-GraphEntityWithPaging -Uri $uri
    
    $total = $policies.Count
    $current = 0
    $found = 0
    
    foreach ($policy in $policies) {
        $current++
        Write-Progress -Activity "Settings Catalog" -Status "$current of $total" -PercentComplete (($current / $total) * 100)
        
        $assignments = Get-EntityAssignments -EntityType "configurationPolicies" -EntityId $policy.id
        
        foreach ($assignment in $assignments) {
            $found++
            Add-AssignmentRecord -Category "Settings Catalog" `
                                -PolicyName $policy.name `
                                -PolicyId $policy.id `
                                -Platform (Get-PolicyPlatform -Policy $policy) `
                                -IsExclusion $assignment.IsExclusion
        }
    }
    
    Write-Host "  Found $found assignments" -ForegroundColor Green
}

function Get-CompliancePolicies {
    Write-Host "Checking Compliance Policies..." -ForegroundColor Yellow
    
    $uri = "$script:GraphEndpoint/beta/deviceManagement/deviceCompliancePolicies"
    $policies = Get-GraphEntityWithPaging -Uri $uri
    
    $total = $policies.Count
    $current = 0
    $found = 0
    
    foreach ($policy in $policies) {
        $current++
        Write-Progress -Activity "Compliance Policies" -Status "$current of $total" -PercentComplete (($current / $total) * 100)
        
        $assignments = Get-EntityAssignments -EntityType "deviceCompliancePolicies" -EntityId $policy.id
        
        foreach ($assignment in $assignments) {
            $found++
            Add-AssignmentRecord -Category "Compliance Policy" `
                                -PolicyName $policy.displayName `
                                -PolicyId $policy.id `
                                -Platform (Get-PolicyPlatform -Policy $policy) `
                                -IsExclusion $assignment.IsExclusion
        }
    }
    
    Write-Host "  Found $found assignments" -ForegroundColor Green
}

function Get-AppProtectionPolicies {
    Write-Host "Checking App Protection Policies..." -ForegroundColor Yellow
    
    $uri = "$script:GraphEndpoint/beta/deviceAppManagement/managedAppPolicies"
    $policies = Get-GraphEntityWithPaging -Uri $uri
    
    $found = 0
    
    foreach ($policy in $policies) {
        $assignments = Get-EntityAssignments -EntityType "managedAppPolicies" -EntityId $policy.id
        
        foreach ($assignment in $assignments) {
            $found++
            Add-AssignmentRecord -Category "App Protection" `
                                -PolicyName $policy.displayName `
                                -PolicyId $policy.id `
                                -Platform (Get-PolicyPlatform -Policy $policy) `
                                -IsExclusion $assignment.IsExclusion
        }
    }
    
    Write-Host "  Found $found assignments" -ForegroundColor Green
}

function Get-AppConfigurationPolicies {
    Write-Host "Checking App Configuration Policies..." -ForegroundColor Yellow
    
    $uri = "$script:GraphEndpoint/beta/deviceAppManagement/mobileAppConfigurations"
    $policies = Get-GraphEntityWithPaging -Uri $uri
    
    $found = 0
    
    foreach ($policy in $policies) {
        $assignments = Get-EntityAssignments -EntityType "mobileAppConfigurations" -EntityId $policy.id
        
        foreach ($assignment in $assignments) {
            $found++
            Add-AssignmentRecord -Category "App Configuration" `
                                -PolicyName $policy.displayName `
                                -PolicyId $policy.id `
                                -Platform "Mobile" `
                                -IsExclusion $assignment.IsExclusion
        }
    }
    
    Write-Host "  Found $found assignments" -ForegroundColor Green
}

function Get-Applications {
    Write-Host "Checking Applications..." -ForegroundColor Yellow
    
    $uri = "$script:GraphEndpoint/beta/deviceAppManagement/mobileApps?`$filter=isAssigned eq true"
    $apps = Get-GraphEntityWithPaging -Uri $uri
    
    # Filter out built-in apps
    $apps = $apps | Where-Object { -not ($_.isFeatured -or $_.isBuiltIn) }
    
    $total = $apps.Count
    $current = 0
    $found = 0
    
    foreach ($app in $apps) {
        $current++
        Write-Progress -Activity "Applications" -Status "$current of $total" -PercentComplete (($current / $total) * 100)
        
        $assignments = Get-EntityAssignments -EntityType "mobileApps" -EntityId $app.id
        
        foreach ($assignment in $assignments) {
            $found++
            $intent = if ($assignment.Intent) { $assignment.Intent } else { "available" }
            
            Add-AssignmentRecord -Category "Application" `
                                -PolicyName $app.displayName `
                                -PolicyId $app.id `
                                -Platform "Multi-Platform" `
                                -IsExclusion $assignment.IsExclusion `
                                -Intent $intent
        }
    }
    
    Write-Host "  Found $found assignments" -ForegroundColor Green
}

function Get-Scripts {
    Write-Host "Checking Scripts..." -ForegroundColor Yellow
    
    $found = 0
    
    # PowerShell Scripts
    $uri = "$script:GraphEndpoint/beta/deviceManagement/deviceManagementScripts"
    $scripts = Get-GraphEntityWithPaging -Uri $uri
    
    foreach ($script in $scripts) {
        $assignments = Get-EntityAssignments -EntityType "deviceManagementScripts" -EntityId $script.id
        
        foreach ($assignment in $assignments) {
            $found++
            Add-AssignmentRecord -Category "PowerShell Script" `
                                -PolicyName $script.displayName `
                                -PolicyId $script.id `
                                -Platform "Windows" `
                                -IsExclusion $assignment.IsExclusion
        }
    }
    
    # Proactive Remediation Scripts
    $uri = "$script:GraphEndpoint/beta/deviceManagement/deviceHealthScripts"
    $healthScripts = Get-GraphEntityWithPaging -Uri $uri
    
    foreach ($script in $healthScripts) {
        $assignments = Get-EntityAssignments -EntityType "deviceHealthScripts" -EntityId $script.id
        
        foreach ($assignment in $assignments) {
            $found++
            Add-AssignmentRecord -Category "Proactive Remediation" `
                                -PolicyName $script.displayName `
                                -PolicyId $script.id `
                                -Platform "Windows" `
                                -IsExclusion $assignment.IsExclusion
        }
    }
    
    Write-Host "  Found $found assignments" -ForegroundColor Green
}

function Get-EndpointSecurityPolicies {
    Write-Host "Checking Endpoint Security Policies..." -ForegroundColor Yellow
    
    $uri = "$script:GraphEndpoint/beta/deviceManagement/intents"
    $intents = Get-GraphEntityWithPaging -Uri $uri
    
    $found = 0
    
    foreach ($intent in $intents) {
        $assignmentsUri = "$script:GraphEndpoint/beta/deviceManagement/intents/$($intent.id)/assignments"
        $assignments = Get-GraphEntityWithPaging -Uri $assignmentsUri
        
        $groupAssignments = $assignments | Where-Object { $_.target.groupId -eq $script:GroupId }
        
        foreach ($assignment in $groupAssignments) {
            $found++
            $isExclusion = $assignment.target.'@odata.type' -eq '#microsoft.graph.exclusionGroupAssignmentTarget'
            
            $category = switch ($intent.templateId) {
                { $_ -match 'antivirus' } { "Endpoint Security - Antivirus" }
                { $_ -match 'diskEncryption' } { "Endpoint Security - Disk Encryption" }
                { $_ -match 'firewall' } { "Endpoint Security - Firewall" }
                { $_ -match 'endpointDetection' } { "Endpoint Security - EDR" }
                { $_ -match 'attackSurface' } { "Endpoint Security - ASR" }
                default { "Endpoint Security - Other" }
            }
            
            Add-AssignmentRecord -Category $category `
                                -PolicyName $intent.displayName `
                                -PolicyId $intent.id `
                                -Platform "Windows" `
                                -IsExclusion $isExclusion
        }
    }
    
    Write-Host "  Found $found assignments" -ForegroundColor Green
}

function Export-Results {
    if ($script:AllAssignments.Count -eq 0) {
        Write-Warning "No assignments found for group: $($script:GroupName)"
        return
    }
    
    try {
        $script:AllAssignments | Export-Csv -Path $script:FinalExportPath -NoTypeInformation -Encoding UTF8
        
        Write-Host "`n=== Export Complete ===" -ForegroundColor Green
        Write-Host "Export Location: " -NoNewline -ForegroundColor Cyan
        Write-Host "$script:FinalExportPath" -ForegroundColor Yellow
        Write-Host "Total Assignments: $($script:AllAssignments.Count)" -ForegroundColor Cyan
        
        # Summary by category
        Write-Host "`n=== Summary by Category ===" -ForegroundColor Cyan
        $script:AllAssignments | Group-Object Category | Sort-Object Count -Descending | ForEach-Object {
            $included = ($_.Group | Where-Object { $_.AssignmentType -eq "Included" }).Count
            $excluded = ($_.Group | Where-Object { $_.AssignmentType -eq "Excluded" }).Count
            Write-Host "$($_.Name): $included included, $excluded excluded" -ForegroundColor Yellow
        }
        
        # List all assignments
        Write-Host "`n=== All Assignments ===" -ForegroundColor Cyan
        foreach ($assignment in $script:AllAssignments | Sort-Object Category, PolicyName) {
            $color = if ($assignment.AssignmentType -eq "Excluded") { "Red" } else { "White" }
            $intentText = if ($assignment.Intent -ne "N/A") { " [$($assignment.Intent)]" } else { "" }
            Write-Host "[$($assignment.Category)] $($assignment.PolicyName)$intentText - $($assignment.AssignmentType)" -ForegroundColor $color
        }
    }
    catch {
        Write-Error "Failed to export results: $_"
    }
}

# Main execution
try {
    Write-Host "`n=== Intune Group Assignment Checker ===" -ForegroundColor Cyan
    Write-Host ""
    
    # Connect to Graph
    if (-not (Connect-MgGraphWithAuth)) {
        throw "Failed to connect to Microsoft Graph"
    }
    
    # Resolve the group
    if (-not (Resolve-Group -Identifier $GroupIdentifier)) {
        throw "Failed to resolve group"
    }
    
    # Initialize export path
    Initialize-ExportPath
    
    # Display group and export information
    Write-Host "`n=== Group Information ===" -ForegroundColor Cyan
    Write-Host "Group Name:      $($script:GroupName)" -ForegroundColor White
    Write-Host "Group ID:        $($script:GroupId)" -ForegroundColor White
    Write-Host "Export Location: " -NoNewline -ForegroundColor White
    Write-Host "$script:FinalExportPath" -ForegroundColor Yellow
    Write-Host ""
    
    Write-Host "Collecting assignments..." -ForegroundColor Cyan
    Write-Host ""
    
    # Collect all assignments
    Get-DeviceConfigurations
    Get-SettingsCatalog
    Get-CompliancePolicies
    Get-AppProtectionPolicies
    Get-AppConfigurationPolicies
    Get-Applications
    Get-Scripts
    Get-EndpointSecurityPolicies
    
    # Export results
    Export-Results
    
    Write-Host "`nDone!" -ForegroundColor Green
}
catch {
    Write-Error "Script execution failed: $_"
    exit 1
}
finally {
    try {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    }
    catch {
        # Ignore disconnect errors
    }
}