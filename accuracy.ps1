<#
.SYNOPSIS  Compare what the lidar measures with a known, tape-measured distance (and optionally angle).
.DESCRIPTION
  Put a flat object (box, book, folded cardboard; matte, light coloured, at least 15 cm wide) in front of the
  sensor and make it the NEAREST thing in view. Measure with a tape from the CENTRE of the sensor's rotating
  head to the object's front face. Keep everything still while the script runs.
  The script captures several revolutions, finds the nearest object in each, and reports the median
  distance/angle, the revolution-to-revolution spread, and the error against what you measured.
.EXAMPLE   powershell -ExecutionPolicy Bypass -File accuracy.ps1 -ExpectedMm 1000
.EXAMPLE   powershell -ExecutionPolicy Bypass -File accuracy.ps1 -ExpectedMm 1000 -ExpectedAngle 90   # object to the right
.EXAMPLE   powershell -ExecutionPolicy Bypass -File accuracy.ps1 -ExpectedMm 424 -RawPath data\raw.bin  # offline logic check
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateRange(150, 12000)][double]$ExpectedMm,
    [ValidateRange(0, 360)][double]$ExpectedAngle = -1,     # degrees clockwise from the sensor's 0; omit to skip the angle check
    [string]$Port = 'COM3',
    [ValidateRange(3, 30)][int]$Seconds = 6,
    [string]$RawPath,
    [string]$Label
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RPLidar.psm1') -Force
$dataDir = Join-Path $PSScriptRoot 'data'
New-Item -ItemType Directory -Force $dataDir | Out-Null

if ($RawPath) { $bytes = [System.IO.File]::ReadAllBytes($RawPath) }
else { $bytes = (Invoke-RplidarCapture -Port $Port -Seconds $Seconds).Bytes }
$dec = ConvertFrom-RplidarScan -Bytes $bytes
if ($dec.Stats.SkippedBytes -gt 0) { Write-Warning "$($dec.Stats.SkippedBytes) bytes skipped while decoding; results may be unreliable." }

$hits = @(Find-RplidarNearestObject -Revolutions $dec.Revolutions)
if ($hits.Count -eq 0) { throw 'No object found. Is something solid and matte within a few metres, and nothing closer?' }

$d = @($hits | ForEach-Object DistanceMm | Sort-Object)
$med = if ($d.Count % 2) { $d[[int][math]::Floor($d.Count / 2)] } else { ($d[$d.Count / 2 - 1] + $d[$d.Count / 2]) / 2 }
$p10 = $d[[int][math]::Floor(($d.Count - 1) * 0.1)]; $p90 = $d[[int][math]::Floor(($d.Count - 1) * 0.9)]
$sx = 0.0; $sy = 0.0
foreach ($h in $hits) { $t = $h.AngleDeg * [math]::PI / 180; $sx += [math]::Sin($t); $sy += [math]::Cos($t) }
$ang = ([math]::Atan2($sx, $sy) * 180 / [math]::PI + 360) % 360
$angSpread = ($hits | ForEach-Object { [math]::Abs((($_.AngleDeg - $ang + 540) % 360) - 180) } | Measure-Object -Maximum).Maximum
$width = ($hits | ForEach-Object WidthDeg | Measure-Object -Average).Average

$err = $med - $ExpectedMm
$tol = 10 + 0.015 * $ExpectedMm       # my pass band: 10 mm + 1.5 % of distance (A1 spec is about 1 % at range)
$inv = [System.Globalization.CultureInfo]::InvariantCulture
"object found in $($hits.Count) of $($dec.Revolutions.Count) revolutions ($([math]::Round(100 * $hits.Count / $dec.Revolutions.Count)) %)"
"distance : measured median {0:F1} mm (10th-90th percentile {1:F1}..{2:F1})   expected {3:F1} mm" -f $med, $p10, $p90, $ExpectedMm
"error    : {0:+0.0;-0.0} mm ({1:+0.00;-0.00} %)   pass band +/- {2:F1} mm" -f $err, (100 * $err / $ExpectedMm), $tol
"angle    : {0:F1} deg (largest deviation between revolutions {1:F1} deg), object width about {2:F1} deg" -f $ang, $angSpread, $width
$pass = [math]::Abs($err) -le $tol
$angErr = $null
if ($ExpectedAngle -ge 0) {
    $angErr = (($ang - $ExpectedAngle + 540) % 360) - 180
    "angle error vs expected {0:F1} deg: {1:+0.0;-0.0} deg   (positive = object is further clockwise than expected)" -f $ExpectedAngle, $angErr
    $pass = $pass -and ([math]::Abs($angErr) -le 3)
}
if ($hits.Count -lt 0.8 * $dec.Revolutions.Count) { Write-Warning 'Object was missed in more than 20 % of revolutions: a darker, shinier or smaller target may be unreliable.' }
if ($pass) { 'PASS' } else { 'FAIL' }

if (-not $RawPath) {   # only real measurements are logged
    $log = Join-Path $dataDir 'accuracy_log.csv'
    if (-not (Test-Path $log)) { Set-Content $log 'timestamp,label,expected_mm,measured_mm,error_mm,expected_deg,measured_deg,angle_error_deg,revolutions_hit,revolutions' -Encoding ascii }
    $f = { param($x, $fmt) if ($null -eq $x) { '' } else { ([double]$x).ToString($fmt, $inv) } }
    Add-Content $log ('{0},{1},{2},{3},{4},{5},{6},{7},{8},{9}' -f (Get-Date -Format 's'), $Label, (& $f $ExpectedMm 'F1'), (& $f $med 'F1'), (& $f $err 'F1'), $(if ($ExpectedAngle -ge 0) { & $f $ExpectedAngle 'F1' } else { '' }), (& $f $ang 'F1'), (& $f $angErr 'F1'), $hits.Count, $dec.Revolutions.Count) -Encoding ascii
    "logged to $log"
}
if (-not $pass) { exit 1 }
