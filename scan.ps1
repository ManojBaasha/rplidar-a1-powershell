<#
.SYNOPSIS  Take a lidar sweep and save it to data\scan.csv (angle_deg,dist_mm,quality,valid).
.DESCRIPTION
  Default: the single revolution with the most valid returns.
  -Fuse  : median-merge every captured revolution (1-degree bins, a bin needs echoes from at least
           -MinSupport different revolutions). Denser and less noisy, but only for a still sensor and scene.
           In fused output the quality column holds the number of revolutions that supported that bin.
.EXAMPLE   powershell -ExecutionPolicy Bypass -File scan.ps1
.EXAMPLE   powershell -ExecutionPolicy Bypass -File scan.ps1 -Fuse
.NOTES     Output goes to .\data, which is git-ignored (scans are a map of your room).
#>
[CmdletBinding()]
param(
    [string]$Port = 'COM3',
    [ValidateRange(2, 30)][int]$Seconds = 4,
    [string]$OutDir,
    [switch]$SaveRaw,         # also keep the raw bytes (data\raw.bin) for offline analysis
    [switch]$Fuse,
    [ValidateRange(1, 100)][int]$MinSupport = 3
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'data' }   # not in param(): $PSScriptRoot is empty there on PS 5.1
Import-Module (Join-Path $PSScriptRoot 'RPLidar.psm1') -Force
New-Item -ItemType Directory -Force $OutDir | Out-Null

$cap = Invoke-RplidarCapture -Port $Port -Seconds $Seconds
if ($SaveRaw) { [System.IO.File]::WriteAllBytes((Join-Path $OutDir 'raw.bin'), $cap.Bytes) }

$dec = ConvertFrom-RplidarScan -Bytes $cap.Bytes
if ($dec.Stats.SkippedBytes -gt 0) { Write-Warning "$($dec.Stats.SkippedBytes) bytes were skipped while re-aligning; run audit.ps1 to investigate." }
$path = Join-Path $OutDir 'scan.csv'
if ($Fuse) {
    $nodes = @(Merge-RplidarRevolutions -Revolutions $dec.Revolutions -BinDeg 1 -MinSupport $MinSupport)
    Export-RplidarCsv -Nodes $nodes -Path $path
    "Fused $($dec.Stats.CompleteRevolutions) revolutions: $($nodes.Count) of 360 one-degree bins have a return (support >= $MinSupport) -> $path"
}
else {
    $sweep = Select-RplidarSweep -Revolutions $dec.Revolutions
    Export-RplidarCsv -Nodes $sweep.Nodes -Path $path
    $valid = @($sweep.Nodes | Where-Object { $_.Valid }).Count
    "Saved revolution $($sweep.Index + 1) of $($dec.Stats.CompleteRevolutions): $valid valid returns out of $($sweep.Nodes.Count) nodes -> $path"
}
