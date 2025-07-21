Clear-Host

$ScriptName = "Compare_Folders_Difference"
$scriptVersion = "V_1_0_29"
$scriptGitHub = "https://github.com/muthdieter"
$scriptDate = "7.2025"

mode 300

Write-Host ""
Write-Host "             ____  __  __"
Write-Host "            |  _ \|  \/  |"
Write-Host "            | | | | |\/| |"
Write-Host "            | |_| | |  | |"
Write-Host "            |____/|_|  |_|"
Write-Host ""
Write-Host "       $scriptGitHub " -ForegroundColor magenta
Write-Host "       $ScriptName   " -ForegroundColor Green
Write-Host "       $scriptVersion" -ForegroundColor Green
Write-Host "       $scriptDate   " -ForegroundColor Green
Write-Host ""
Write-Host "      Output: Source  - Files only in Source Folder" -ForegroundColor Green
Write-Host "      Output: Both    - Files in both Folders" -ForegroundColor Green
Write-Host "      Output: Target  - Files only in Target Folder" -ForegroundColor Green
Write-Host ""
Pause

# -----------------------  GUI FOLDER PICKER  -----------------
function Pick-Folder ([string]$title) {
    Add-Type -AssemblyName System.Windows.Forms
    $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderBrowser.Description = $title
    if ($folderBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $folderBrowser.SelectedPath
    }
    return $null
}

# -----------------------  SELECT FOLDERS  ---------------------
$SourceFolder = Pick-Folder "Select the SOURCE folder"
if (-not $SourceFolder) { Write-Host "Cancelled." ; exit 1 }

$TargetFolder = Pick-Folder "Select the TARGET folder"
if (-not $TargetFolder) { Write-Host "Cancelled." ; exit 1 }

$SourceFolder = $SourceFolder.TrimEnd('\')
$TargetFolder = $TargetFolder.TrimEnd('\')

Write-Host "`nSource : $SourceFolder"
Write-Host "Target : $TargetFolder`n"

# ----------------------- TEMP SETUP ---------------------------
$scriptDir = $PSScriptRoot; if (-not $scriptDir) { $scriptDir = Get-Location }
$TempDir = Join-Path $scriptDir ".temp"
if (-not (Test-Path $TempDir)) {
    New-Item -ItemType Directory -Path $TempDir | Out-Null
}

# ------------------ FILE SCANNING TO TEMP ---------------------
function Get-FolderStats {
    param (
        [string]$Path,
        [string]$Label,
        [string]$OutFile
    )
    Write-Host "`nScanning $Label folder..." -ForegroundColor Yellow
    $progressCount = 0
    Remove-Item -Path $OutFile -ErrorAction SilentlyContinue

    Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        $progressCount++
        $line = '{0}|{1}|{2}' -f $_.FullName, $_.Length, $_.Name
        Add-Content -Path $OutFile -Value $line
        if ($progressCount % 500 -eq 0) {
            Write-Progress -Activity "Scanning $Label folder..." -Status "$progressCount files..." -PercentComplete 0
        }
    }

    Write-Progress -Activity "Scanning $Label folder..." -Completed
}

function Load-FilesFromTemp($filePath) {
    Get-Content $filePath | ForEach-Object {
        $parts = $_ -split '\|', 3
        [PSCustomObject]@{
            FullName = $parts[0]
            Length   = [int64]$parts[1]
            Name     = $parts[2]
        }
    }
}

function Estimate-Time { param ($count) ; return [math]::Ceiling($count * 0.01) }
function Sanitize-Name($name) { return ($name -replace '[^a-zA-Z0-9]', '_') }

# ------------------- GET SCAN TYPE -----------------------------
$compareType = Read-Host "`nChoose comparison type: (Q)uick or (E)xtended (includes hash)? [Q/E]"
$useExtended = $compareType -in @('E', 'e')

# ------------------- SCAN FOLDERS -----------------------------
$sourceList = Join-Path $TempDir "source.txt"
$targetList = Join-Path $TempDir "target.txt"
Get-FolderStats -Path $SourceFolder -Label "Source" -OutFile $sourceList
Get-FolderStats -Path $TargetFolder -Label "Target" -OutFile $targetList

$sourceFiles = Load-FilesFromTemp $sourceList
$targetFiles = Load-FilesFromTemp $targetList

$totalFiles = $sourceFiles.Count + $targetFiles.Count
$totalSizeMB = [math]::Round(($sourceFiles | Measure-Object Length -Sum).Sum + ($targetFiles | Measure-Object Length -Sum).Sum) / 1MB
$estimatedSec = Estimate-Time -count $totalFiles
$estimatedMin = [math]::Round($estimatedSec / 60, 2)

Write-Host "`nTotal files to compare : $totalFiles"
Write-Host "Total data size         : $totalSizeMB MB"
Write-Host "Estimated time needed   : $estimatedSec seconds (~$estimatedMin min)"

$response = Read-Host "`nProceed with comparison? (Y/N)"
Write-Host ""
if ($response -notin @('Y', 'y')) {
    Write-Host "`nUser canceled. Exiting..." -ForegroundColor Yellow
    exit
}

function Build-FileMap($files, $basePath) {
    $map = @{}
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($basePath.TrimEnd('\').Length).TrimStart("\")
        $map[$rel] = $f
    }
    return $map
}

$sourceMap = Build-FileMap $sourceFiles $SourceFolder
$targetMap = Build-FileMap $targetFiles $TargetFolder

$movedFiles = @()
$srcGrouped = @{}
$trgGrouped = @{}

foreach ($f in $sourceFiles) {
    $key = "$($f.Name.ToLowerInvariant())|$($f.Length)"
    if (-not $srcGrouped.ContainsKey($key)) { $srcGrouped[$key] = @() }
    $srcGrouped[$key] += $f
}
foreach ($f in $targetFiles) {
    $key = "$($f.Name.ToLowerInvariant())|$($f.Length)"
    if (-not $trgGrouped.ContainsKey($key)) { $trgGrouped[$key] = @() }
    $trgGrouped[$key] += $f
}

foreach ($key in $srcGrouped.Keys) {
    if ($trgGrouped.ContainsKey($key)) {
        foreach ($srcFile in $srcGrouped[$key]) {
            foreach ($tgtFile in $trgGrouped[$key]) {
                $srcRel = $srcFile.FullName.Substring($SourceFolder.Length).TrimStart("\")
                $tgtRel = $tgtFile.FullName.Substring($TargetFolder.Length).TrimStart("\")
                if ($srcRel -ne $tgtRel) {
                    $movedFiles += [PSCustomObject]@{
                        Name       = $srcFile.Name
                        SourcePath = $srcRel
                        TargetPath = $tgtRel
                        Size       = $srcFile.Length
                    }
                }
            }
        }
    }
}

# ------------------- COMPARE FILES -----------------------------
$results = [System.Collections.Generic.List[object]]::new()
$totalToCompare = $sourceFiles.Count + $targetFiles.Count
$currentIndex = 0

foreach ($relPath in $sourceMap.Keys) {
    $currentIndex++
    Write-Progress -Activity "Comparing folders..." -Status "$relPath" -PercentComplete (($currentIndex / $totalToCompare) * 100)

    $src = $sourceMap[$relPath]
    $tgt = $targetMap[$relPath]

    if ($tgt) {
        $isDiff = $src.Length -ne $tgt.Length
        if (-not $isDiff -and $useExtended) {
            try {
                $srcHash = (Get-FileHash $src.FullName -ErrorAction Stop).Hash
                $tgtHash = (Get-FileHash $tgt.FullName -ErrorAction Stop).Hash
                $isDiff = $srcHash -ne $tgtHash
            } catch {
                Write-Warning ("Failed to hash {0}: {1}" -f $relPath, $_)
                $isDiff = $true
            }
        }

        $results.Add([PSCustomObject]@{
            Location     = "Both"
            RelativePath = $relPath
            Name         = $src.Name
            Size         = $src.Length
        })
        $targetMap.Remove($relPath)
    } else {
        $results.Add([PSCustomObject]@{
            Location     = "Source"
            RelativePath = $relPath
            Name         = $src.Name
            Size         = $src.Length
        })
    }
}

foreach ($relPath in $targetMap.Keys) {
    $file = $targetMap[$relPath]
    $results.Add([PSCustomObject]@{
        Location     = "Target"
        RelativePath = $relPath
        Name         = $file.Name
        Size         = $file.Length
    })
}

Write-Progress -Activity "Comparing folders..." -Completed

# ------------------- EXPORT RESULTS -----------------------------
Write-Host "`nChoose output format:" -ForegroundColor Yellow
Write-Host "`n1. CSV (.csv)"
Write-Host "2. Text (.txt)"
Write-Host "3. HTML (.html)"
$outputChoice = Read-Host "`nEnter your choice (1-3)"

$srcName = Sanitize-Name (Split-Path $SourceFolder -Leaf)
$tgtName = Sanitize-Name (Split-Path $TargetFolder -Leaf)
$timeTag = Get-Date -Format "yyyy-MM-dd_HHmmss"

switch ($outputChoice) {
    '2' { $ext = 'txt' }
    '3' { $ext = 'html' }
    default { $ext = 'csv' }
}

$outputFile = Join-Path $scriptDir "$srcName`_VS_`$tgtName`_$timeTag.$ext"

switch ($ext) {
    'csv' { $results | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8 }
    'txt' {
        $lines = $results | Format-Table -AutoSize | Out-String
        Add-Content -Path $outputFile -Value $lines
    }
    'html' {
        $results | ConvertTo-Html -Title "Folder Comparison Report" | Set-Content -Path $outputFile -Encoding UTF8
    }
}

if ($movedFiles.Count -gt 0 -and $ext -ne 'html') {
    Add-Content -Path $outputFile -Value "`n=== Moved Files ==="
    $movedText = $movedFiles | Format-Table -AutoSize | Out-String
    Add-Content -Path $outputFile -Value $movedText
}

Write-Host "`nComparison complete. Output saved to:" -ForegroundColor Green
Write-Host "`n  $outputFile" -ForegroundColor Cyan
Invoke-Item $outputFile

# ------------------- CLEANUP -----------------------------
try {
    Remove-Item -Path $TempDir -Recurse -Force
} catch {
    Write-Warning "Failed to clean up temp folder: $_"
}

Write-Host ""
Write-Host "  _______ _                 _"
Write-Host " |__   __| |               | |"
Write-Host "    | |  | |__   __ _ _ __ | | _ "
Write-Host "    | |  | '_ \ / _\` | '_ \| | /"
Write-Host "    | |  | | | | (_| | | | |   < "
Write-Host "    |_|  |_| |_|\__,_|_| |_|_|\_\"
Write-Host ""
pause
