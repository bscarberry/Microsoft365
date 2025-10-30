<#
.SYNOPSIS
    Adds folders older than one year to a Microsoft Purview Information Protection Scanner content scan job.

.DESCRIPTION
    This script scans a parent directory for subfolders, checks their creation date, and automatically
    adds folders created over one year ago as repositories to the Purview Information Protection Scanner
    content scan job. It includes error handling, logging, and supports both UNC paths and local paths.

.PARAMETER ParentPath
    The root path to scan for folders. Can be a UNC path (\\server\share) or local path (C:\Data).

.PARAMETER AgeThresholdYears
    The age threshold in years. Folders older than this will be added. Default is 1 year.

.PARAMETER Recursive
    If specified, searches for folders recursively. Default is top-level only.

.PARAMETER WhatIf
    Shows what would happen without making changes.

.PARAMETER ExcludeExisting
    If specified, skips folders that are already configured as repositories.

.PARAMETER LogPath
    Path to the log file. Default is %TEMP%\PurviewScannerFolderAdd.log

.PARAMETER OverrideContentScanJob
    If specified, allows repository-specific settings. Default is Off (inherit from content scan job).

.PARAMETER EnableDlp
    Enable DLP for added repositories. Valid values: On, Off. Default inherits from content scan job.

.PARAMETER Enforce
    Enable policy enforcement for added repositories. Valid values: On, Off. Default inherits from content scan job.

.EXAMPLE
    .\Add-OldFoldersToScannerJob.ps1 -ParentPath "\\FileServer\Archive" -AgeThresholdYears 1

.EXAMPLE
    .\Add-OldFoldersToScannerJob.ps1 -ParentPath "C:\CompanyData" -Recursive -WhatIf

.EXAMPLE
    .\Add-OldFoldersToScannerJob.ps1 -ParentPath "\\FileServer\Shares" -EnableDlp On -Enforce On

.NOTES
    Author: IT Security Team
    Version: 1.0
    Requires: PurviewInformationProtection PowerShell module
    Requires: Microsoft Purview Information Protection Scanner installed and configured
    
    Prerequisites:
    - Scanner must be installed via Install-Scanner cmdlet
    - Content scan job must be configured via Set-ScannerContentScan or Purview portal
    - Authentication token must be set via Set-Authentication cmdlet
    - User must have permissions to access the parent path and modify scanner configuration
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true, HelpMessage="Root path to scan for folders (UNC or local path)")]
    [ValidateNotNullOrEmpty()]
    [string]$ParentPath,
    
    [Parameter(Mandatory=$false)]
    [ValidateRange(0, 100)]
    [int]$AgeThresholdYears = 1,
    
    [Parameter(Mandatory=$false)]
    [switch]$Recursive,
    
    [Parameter(Mandatory=$false)]
    [switch]$ExcludeExisting,
    
    [Parameter(Mandatory=$false)]
    [string]$LogPath = "$env:TEMP\PurviewScannerFolderAdd_$(Get-Date -Format 'yyyyMMdd_HHmmss').log",
    
    [Parameter(Mandatory=$false)]
    [ValidateSet('On', 'Off')]
    [string]$OverrideContentScanJob = 'Off',
    
    [Parameter(Mandatory=$false)]
    [ValidateSet('On', 'Off', $null)]
    [string]$EnableDlp = $null,
    
    [Parameter(Mandatory=$false)]
    [ValidateSet('On', 'Off', $null)]
    [string]$Enforce = $null
)

#region Functions

function Write-Log {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        
        [Parameter(Mandatory=$false)]
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logMessage = "[$timestamp] [$Level] $Message"
    
    # Console output with colors
    switch ($Level) {
        'Info'    { Write-Host $logMessage -ForegroundColor Cyan }
        'Warning' { Write-Warning $logMessage }
        'Error'   { Write-Error $logMessage }
        'Success' { Write-Host $logMessage -ForegroundColor Green }
    }
    
    # File output
    Add-Content -Path $LogPath -Value $logMessage -ErrorAction SilentlyContinue
}

function Test-PurviewModule {
    if (-not (Get-Module -ListAvailable -Name PurviewInformationProtection)) {
        Write-Log "PurviewInformationProtection module is not installed. Please install the Microsoft Purview Information Protection client." -Level Error
        return $false
    }
    
    try {
        Import-Module PurviewInformationProtection -ErrorAction Stop
        Write-Log "Successfully imported PurviewInformationProtection module." -Level Success
        return $true
    }
    catch {
        Write-Log "Failed to import PurviewInformationProtection module: $_" -Level Error
        return $false
    }
}

function Test-ScannerConfiguration {
    try {
        # Test if scanner is configured by attempting to get content scan job
        $scanJob = Get-ScannerContentScan -ErrorAction Stop
        Write-Log "Scanner content scan job found and accessible." -Level Success
        return $true
    }
    catch {
        Write-Log "Cannot access scanner content scan job. Ensure scanner is installed and configured. Error: $_" -Level Error
        return $false
    }
}

function Get-ExistingRepositories {
    try {
        $repos = Get-ScannerRepository -ErrorAction Stop
        if ($repos) {
            Write-Log "Found $(@($repos).Count) existing repositories in content scan job." -Level Info
            return $repos
        }
        else {
            Write-Log "No existing repositories found in content scan job." -Level Info
            return @()
        }
    }
    catch {
        Write-Log "Error retrieving existing repositories: $_" -Level Warning
        return @()
    }
}

function Get-OldFolders {
    param(
        [string]$Path,
        [int]$AgeYears,
        [bool]$RecursiveSearch
    )
    
    Write-Log "Scanning path: $Path" -Level Info
    Write-Log "Age threshold: $AgeYears year(s)" -Level Info
    Write-Log "Recursive search: $RecursiveSearch" -Level Info
    
    $cutoffDate = (Get-Date).AddYears(-$AgeYears)
    Write-Log "Cutoff date: $($cutoffDate.ToString('yyyy-MM-dd'))" -Level Info
    
    try {
        # Get folders based on recursive parameter
        if ($RecursiveSearch) {
            $folders = Get-ChildItem -Path $Path -Directory -Recurse -ErrorAction Stop
        }
        else {
            $folders = Get-ChildItem -Path $Path -Directory -ErrorAction Stop
        }
        
        Write-Log "Found $($folders.Count) total folders in path." -Level Info
        
        # Filter folders by creation date
        $oldFolders = $folders | Where-Object { $_.CreationTime -lt $cutoffDate }
        
        Write-Log "Found $($oldFolders.Count) folders older than $AgeYears year(s)." -Level Success
        
        return $oldFolders
    }
    catch {
        Write-Log "Error accessing path '$Path': $_" -Level Error
        return @()
    }
}

function Add-FolderToScanner {
    param(
        [Parameter(Mandatory=$true)]
        [System.IO.DirectoryInfo]$Folder,
        
        [Parameter(Mandatory=$false)]
        [string]$OverrideSettings,
        
        [Parameter(Mandatory=$false)]
        [string]$DlpSetting,
        
        [Parameter(Mandatory=$false)]
        [string]$EnforceSetting
    )
    
    $folderPath = $Folder.FullName
    
    try {
        # Build the Add-ScannerRepository parameters
        $addParams = @{
            Path = $folderPath
            ErrorAction = 'Stop'
        }
        
        # Add optional parameters if override is enabled
        if ($OverrideSettings -eq 'On') {
            $addParams['OverrideContentScanJob'] = 'On'
            
            if ($DlpSetting) {
                $addParams['EnableDlp'] = $DlpSetting
            }
            
            if ($EnforceSetting) {
                $addParams['Enforce'] = $EnforceSetting
            }
        }
        
        # Add repository
        if ($PSCmdlet.ShouldProcess($folderPath, "Add repository to scanner content scan job")) {
            Add-ScannerRepository @addParams
            Write-Log "Successfully added repository: $folderPath" -Level Success
            return $true
        }
        else {
            Write-Log "WhatIf: Would add repository: $folderPath" -Level Info
            return $false
        }
    }
    catch {
        Write-Log "Failed to add repository '$folderPath': $_" -Level Error
        return $false
    }
}

#endregion

#region Main Script

Write-Log "=== Script Started ===" -Level Info
Write-Log "Parent Path: $ParentPath" -Level Info
Write-Log "Age Threshold: $AgeThresholdYears year(s)" -Level Info
Write-Log "Recursive: $Recursive" -Level Info
Write-Log "Exclude Existing: $ExcludeExisting" -Level Info
Write-Log "Log Path: $LogPath" -Level Info

# Validate parent path exists
if (-not (Test-Path -Path $ParentPath -PathType Container)) {
    Write-Log "Parent path does not exist or is not accessible: $ParentPath" -Level Error
    exit 1
}

# Check if PurviewInformationProtection module is available
if (-not (Test-PurviewModule)) {
    Write-Log "Cannot proceed without PurviewInformationProtection module." -Level Error
    exit 1
}

# Test scanner configuration
if (-not (Test-ScannerConfiguration)) {
    Write-Log "Cannot proceed without properly configured scanner." -Level Error
    Write-Log "Please ensure scanner is installed via Install-Scanner and configured via Set-ScannerContentScan or the Purview portal." -Level Error
    exit 1
}

# Get existing repositories if ExcludeExisting is specified
$existingRepos = @()
if ($ExcludeExisting) {
    Write-Log "ExcludeExisting flag set. Retrieving current repositories..." -Level Info
    $existingRepos = Get-ExistingRepositories
    
    # Extract paths from existing repositories for comparison
    $existingPaths = @()
    if ($existingRepos) {
        foreach ($repo in $existingRepos) {
            if ($repo.Path) {
                $existingPaths += $repo.Path
            }
        }
    }
}

# Get folders older than threshold
Write-Log "Searching for folders older than $AgeThresholdYears year(s)..." -Level Info
$oldFolders = Get-OldFolders -Path $ParentPath -AgeYears $AgeThresholdYears -RecursiveSearch $Recursive

if ($oldFolders.Count -eq 0) {
    Write-Log "No folders found matching criteria. Script completed." -Level Info
    exit 0
}

# Display summary of folders found
Write-Log "=== Folders Found ===" -Level Info
foreach ($folder in $oldFolders) {
    $age = (Get-Date) - $folder.CreationTime
    $ageYears = [math]::Round($age.TotalDays / 365, 2)
    Write-Log "  - $($folder.FullName) (Created: $($folder.CreationTime.ToString('yyyy-MM-dd')), Age: $ageYears years)" -Level Info
}

# Add folders to scanner
Write-Log "=== Adding Folders to Scanner ===" -Level Info
$successCount = 0
$skipCount = 0
$failCount = 0

foreach ($folder in $oldFolders) {
    # Check if folder is already in repositories
    if ($ExcludeExisting -and $existingPaths -contains $folder.FullName) {
        Write-Log "Skipping (already exists): $($folder.FullName)" -Level Warning
        $skipCount++
        continue
    }
    
    # Add folder to scanner
    $result = Add-FolderToScanner -Folder $folder `
                                   -OverrideSettings $OverrideContentScanJob `
                                   -DlpSetting $EnableDlp `
                                   -EnforceSetting $Enforce
    
    if ($result) {
        $successCount++
    }
    else {
        $failCount++
    }
    
    # Add small delay to avoid overwhelming the system
    Start-Sleep -Milliseconds 100
}

# Summary
Write-Log "=== Script Completed ===" -Level Success
Write-Log "Total folders found: $($oldFolders.Count)" -Level Info
Write-Log "Successfully added: $successCount" -Level Success
Write-Log "Skipped (already exist): $skipCount" -Level Info
Write-Log "Failed: $failCount" -Level $(if ($failCount -gt 0) { 'Warning' } else { 'Info' })

# Display current repository count
try {
    $finalRepos = Get-ScannerRepository
    $finalCount = if ($finalRepos) { @($finalRepos).Count } else { 0 }
    Write-Log "Total repositories in content scan job: $finalCount" -Level Info
}
catch {
    Write-Log "Could not retrieve final repository count." -Level Warning
}

Write-Log "Log file saved to: $LogPath" -Level Info

#endregion

# Exit with appropriate code
if ($failCount -gt 0) {
    exit 1
}
else {
    exit 0
}
