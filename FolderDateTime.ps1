<#
.SYNOPSIS
    Simple script to find folders older than 1 year.

.DESCRIPTION
    Scans a path and displays folders created more than 1 year ago.
#>

# ============================================
# CONFIGURATION - Modify these variables
# ============================================

$TargetPath = "\\FileServer\Archive"
$AgeThresholdYears = 1

# ============================================
# SCRIPT
# ============================================

# Calculate cutoff date
$CutoffDate = (Get-Date).AddYears(-$AgeThresholdYears)

Write-Host "Scanning: $TargetPath"
Write-Host "Looking for folders created before: $($CutoffDate.ToString('yyyy-MM-dd'))"
Write-Host ""

# Get folders older than threshold
$OldFolders = Get-ChildItem -Path $TargetPath -Directory | 
              Where-Object { $_.CreationTime -lt $CutoffDate }

# Display results
Write-Host "Found $($OldFolders.Count) folders older than $AgeThresholdYears year(s):"
Write-Host ""

foreach ($folder in $OldFolders) {
    $age = [math]::Round(((Get-Date) - $folder.CreationTime).TotalDays / 365, 2)
    Write-Host "$($folder.FullName) - Created: $($folder.CreationTime.ToString('yyyy-MM-dd')) - Age: $age years"
}
