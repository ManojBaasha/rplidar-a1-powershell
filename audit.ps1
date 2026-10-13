<#
.SYNOPSIS  Check that a lidar capture is complete and trustworthy.
.DESCRIPTION
  Captures live (default) or re-analyses a saved raw file, then reports integrity, shape and repeatability.
  For the repeatability numbers keep the sensor and the room still while it runs.
.EXAMPLE   powershell -ExecutionPolicy Bypass -File audit.ps1
.EXAMPLE   powershell -ExecutionPolicy Bypass -File audit.ps1 -RawPath data\raw.bin
#>
[CmdletBinding()]
param(
    [string]$Port = 'COM3',
    [ValidateRange(3, 30)][int]$Seconds = 8,
    [string]$RawPath,
    [string]$OutDir
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'data' }   # not in param(): $PSScriptRoot is empty there on PS 5.1
Import-Module (Join-Path $PSScriptRoot 'RPLidar.psm1') -Force
New-Item -ItemType Directory -Force $OutDir | Out-Null

$elapsed = $null; $first = $null
if ($RawPath) { $bytes = [System.IO.File]::ReadAllBytes($RawPath) }
else {
    $cap = Invoke-RplidarCapture -Port $Port -Seconds $Seconds
    $bytes = $cap.Bytes; $elapsed = $cap.ElapsedSeconds; $first = $cap.FirstDataSeconds
    [System.IO.File]::WriteAllBytes((Join-Path $OutDir 'raw.bin'), $bytes)
}
$dec = ConvertFrom-RplidarScan -Bytes $bytes
$a = Get-RplidarAudit -Decoded $dec -ElapsedSeconds $elapsed -FirstDataSeconds $first
$s = $a.Stats

"== Integrity =="
"bytes captured            : $($s.TotalBytes)"
"nodes decoded             : $($s.Nodes)  (bytes = 7-byte header + 5 x nodes + $($s.SkippedBytes) skipped + $($s.LeftoverBytes) leftover)"
"bytes skipped (re-align)  : $($s.SkippedBytes)   <- 0 means no byte was lost or corrupted"
"leftover bytes            : $($s.LeftoverBytes)   <- incomplete node at the very end (0-4 is normal)"
"complete revolutions      : $($s.CompleteRevolutions)  (excluded: $($s.NodesBeforeFirstStart) nodes before the first start flag, $($s.NodesInPartialLastRev) in the unfinished last one)"
if ($a.Rate) { "throughput               : $($a.Rate.NodesPerSec) nodes/s, about $($a.Rate.RevsPerSec) revolutions/s" }
""
$pr = $a.PerRevolution
function Stat($prop) { $m = $pr | Measure-Object $prop -Minimum -Maximum -Average; '{0}..{1} (avg {2:F1})' -f $m.Minimum, $m.Maximum, $m.Average }
"== Per revolution ($($pr.Count) revolutions) =="
"nodes per revolution      : $(Stat Nodes)"
"valid returns             : $(Stat Valid)"
"no-return nodes           : $(Stat NoReturn)   (laser got no echo; their angles are unreliable and are ignored)"
"holes > 3 deg between valid returns : $(Stat Holes)"
"largest hole (deg)        : $(Stat MaxGapDeg)"
"first angle of a revolution: $(Stat FirstAngle)  (start flag is not at exactly 0 deg)"
""
"== Repeatability, $($a.Bins.Revolutions) revolutions, $($a.Bins.BinDeg)-degree bins (assumes a static scene) =="
"persistent  (valid in >= 90% of revolutions) : $($a.Bins.Persistent) of $($a.Bins.Count) bins"
"intermittent (valid in some revolutions)      : $($a.Bins.Intermittent) of $($a.Bins.Count) bins   <- dots that flicker"
"never valid                                   : $($a.Bins.Never) of $($a.Bins.Count) bins   <- no echo at all (too far/close, glass, black or shiny surface, blocked)"
"fraction of bin-revolutions with a return     : $($a.Bins.ValidFraction)"
if ($null -ne $a.DistanceSpreadMm.Median) { "distance spread per bin (max-min over revolutions): median $($a.DistanceSpreadMm.Median) mm, 90th percentile $($a.DistanceSpreadMm.P90) mm over $($a.DistanceSpreadMm.BinsCompared) bins (upper bound: includes angular jitter)" }
""
"== Checks =="
$checks = [ordered]@{
    'no bytes skipped or corrupted'                     = ($s.SkippedBytes -eq 0)
    'no partial node left at end of data (< 5 bytes)'   = ($s.LeftoverBytes -lt 5)
    'every revolution wraps 360 -> 0 exactly once'      = (@($pr | Where-Object { $_.Wraps -ne 1 }).Count -eq 0)
    'valid angles never go backwards within a revolution' = (@($pr | Where-Object { $_.BackwardSteps -ne 0 }).Count -eq 0)
    'at least 10 complete revolutions'                  = ($pr.Count -ge 10)
}
foreach ($k in $checks.Keys) { '{0}  {1}' -f $(if ($checks[$k]) { 'PASS' } else { 'FAIL' }), $k }
if ($checks.Values -contains $false) { exit 1 }
