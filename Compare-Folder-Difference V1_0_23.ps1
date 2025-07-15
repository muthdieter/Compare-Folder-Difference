Clear-Host

$ScriptName = "Compare_Folders_Difference"
$scriptVersion = "V_1_0_23"
$scriptGitHub = "https://github.com/muthdieter"
$scriptDate = "7.2025"

mode 300

Write-Host ""
Write-Host "             ____  __  __"
Write-Host "            |  _ \|  \/  |"
Write-Host "            | | | | |\/| |"
Write-Host "            | |_| | |  | |"
Write-Host "            |____/|_|  |_|"
Write-Host "   "
Write-Host ""
Write-Host "       $scriptGitHub " -ForegroundColor magenta
Write-Host ""
Write-Host "       $ScriptName   " -ForegroundColor Green
write-Host "       $scriptVersion" -ForegroundColor Green
write-host "       $scriptDate   " -ForegroundColor Green
Write-Host ""
Pause
write-Host ""
Write-Host "      Output: Source  - Files only in Source Folder" -ForegroundColor Green
Write-Host "      Output: Both    - Files in both Folders" -ForegroundColor Green
Write-Host "      Output: Target  - Files only in Target Folder" -ForegroundColor Green
write-Host ""
Pause

# Folder Picker
Add-Type -AssemblyName System.Windows.Forms
function Pick-Folder($prompt) {
    Write-Host "`n           $prompt" -ForegroundColor Cyan
    $browser = New-Object System.Windows.Forms.FolderBrowserDialog
    $browser.Description = $prompt
    $null = $browser.ShowDialog()
    return $browser.SelectedPath
}

$SourceFolder = Pick-Folder "Select the SOURCE folder"
if (-not $SourceFolder -or -not (Test-Path $SourceFolder)) {
    Write-Host "Cancelled or invalid source folder selected. Exiting." -ForegroundColor Red
    exit 1
}

$TargetFolder = Pick-Folder "Select the TARGET folder"
if (-not $TargetFolder -or -not (Test-Path $TargetFolder)) {
    Write-Host "Cancelled or invalid target folder selected. Exiting." -ForegroundColor Red
    exit 1
}

# Fast Folder Stats
function Get-FolderStats {
    param ([string]$Path, [string]$Label)
    write-Host ""
    Write-Host "Scanning $Label folder..." -ForegroundColor Yellow
    $files = [System.Collections.Generic.List[object]]::new()
    $progressCount = 0

    Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        $files.Add($_)
        $progressCount++
        if ($progressCount % 500 -eq 0) {
            Write-Progress -Activity "Scanning $Label folder..." -Status "$progressCount files..." -PercentComplete 0
        }
    }

    Write-Progress -Activity "Scanning $Label folder..." -Completed
    $totalSize = ($files | Measure-Object -Property Length -Sum).Sum
    return @{ Size = $totalSize; Count = $files.Count; Files = $files }
}

function Estimate-Time { param ($count) ; return [math]::Ceiling($count * 0.01) }
function Sanitize-Name($name) { return ($name -replace '[^a-zA-Z0-9]', '_') }

# Begin stats
Write-Host "`nCollecting folder statistics..." -ForegroundColor Cyan
$sourceStats = Get-FolderStats -Path $SourceFolder -Label "Source"
$targetStats = Get-FolderStats -Path $TargetFolder -Label "Target"

$totalFiles = $sourceStats.Count + $targetStats.Count
$totalSizeMB = [math]::Round(($sourceStats.Size + $targetStats.Size) / 1MB, 2)
$estimatedSec = Estimate-Time -count $totalFiles
$estimatedMin = [math]::Round($estimatedSec / 60, 2)

Write-Host "`nTotal files to compare : $totalFiles"
Write-Host "Total data size         : $totalSizeMB MB"
Write-Host "Estimated time needed   : $estimatedSec seconds (~$estimatedMin min)"

$response = Read-Host "`nProceed with comparison? (Y/N)"
write-host ""
if ($response -notin @('Y', 'y')) {
    Write-Host "`nUser canceled. Exiting..." -ForegroundColor Yellow
    exit
}
write-host ""
$compareType = Read-Host "Choose comparison type: (Q)uick or (E)xtended (includes hash)? [Q/E]"
$useExtended = $compareType -in @('E', 'e')

$sourceFiles = $sourceStats.Files
$targetFiles = $targetStats.Files

# Mapping helpers
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

# MOVED Files Detection
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
                $srcRel = $srcFile.FullName.Substring($SourceFolder.TrimEnd('\').Length).TrimStart("\")
                $tgtRel = $tgtFile.FullName.Substring($TargetFolder.TrimEnd('\').Length).TrimStart("\")
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

# Actual Comparison
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
            $srcHash = (Get-FileHash $src.FullName).Hash
            $tgtHash = (Get-FileHash $tgt.FullName).Hash
            $isDiff = $srcHash -ne $tgtHash
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

# === Output Format Prompt ===
Write-Host "`nChoose output format:" -ForegroundColor Yellow
write-host ""
Write-Host "1. CSV (.csv)"
Write-Host "2. Text (.txt)"
Write-Host "3. HTML (.html)"
write-host ""
$outputChoice = Read-Host "Enter your choice (1-3)"

$srcName = Sanitize-Name (Split-Path $SourceFolder -Leaf)
$tgtName = Sanitize-Name (Split-Path $TargetFolder -Leaf)
$timeTag = Get-Date -Format "yyyy-MM-dd_HHmmss"
$scriptDir = $PSScriptRoot; if (-not $scriptDir) { $scriptDir = Get-Location }

switch ($outputChoice) {
    '2' { $ext = 'txt' }
    '3' { $ext = 'html' }
    default { $ext = 'csv' }
}

$outputFile = Join-Path $scriptDir "$srcName`_VS_`$tgtName`_$timeTag.$ext"

# === Save Output ===
switch ($ext) {
    'csv' {
        $results | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8
    }
    'txt' {
        $lines = $results | Format-Table -AutoSize | Out-String
        Add-Content -Path $outputFile -Value $lines
    }
    'html' {
        $results | ConvertTo-Html -Title "Folder Comparison Report" | Set-Content -Path $outputFile -Encoding UTF8
    }
}

# Add moved files if not HTML
if ($movedFiles.Count -gt 0 -and $ext -ne 'html') {
    Add-Content -Path $outputFile -Value "`n=== Moved Files ==="
    $movedText = $movedFiles | Format-Table -AutoSize | Out-String
    Add-Content -Path $outputFile -Value $movedText
}

Write-Host "`nComparison complete. Output saved to:" -ForegroundColor Green
write-host ""
Write-Host "  $outputFile" -ForegroundColor Cyan
Invoke-Item $outputFile

write-Host ""
Write-Host ""
Write-Host "  _______ _                 _                      "
Write-Host " |__   __| |               | |                     "
Write-Host "    | |  | |__   __ _ _ __ | | _ "
Write-Host "    | |  | '_ \ / _\` | '_ \| | /"
Write-Host "    | |  | | | | (_| | | | |   < "
Write-Host "    |_|  |_| |_|\__,_|_| |_|_|\_\"
Write-Host ""

