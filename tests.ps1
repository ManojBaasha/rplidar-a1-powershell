# tests.ps1 - hardware-free tests for RPLidar.psm1. Run: powershell -ExecutionPolicy Bypass -File tests.ps1
Set-StrictMode -Version Latest
Import-Module "$PSScriptRoot\RPLidar.psm1" -Force

$script:failed = 0; $script:passed = 0
function Assert-Equal($actual, $expected, [string]$what) {
    if ($actual -eq $expected) { $script:passed++ } else { $script:failed++; Write-Host "FAIL  $what : expected [$expected] got [$actual]" -ForegroundColor Red }
}
function Assert-Near($actual, $expected, [double]$tol, [string]$what) {
    if ([math]::Abs($actual - $expected) -le $tol) { $script:passed++ } else { $script:failed++; Write-Host "FAIL  $what : expected ~$expected got $actual" -ForegroundColor Red }
}

# --- test encoder: the inverse of the protocol, written independently of the decoder ---
function New-Node([double]$angle, [double]$dist, [int]$quality, [bool]$start) {
    $q6 = [int][math]::Round($angle * 64); $d2 = [int][math]::Round($dist * 4)
    $b0 = ($quality -shl 2) -bor $(if ($start) { 1 } else { 2 })
    [byte[]]@($b0, ((($q6 -band 0x7F) -shl 1) -bor 1), ($q6 -shr 7), ($d2 -band 0xFF), ($d2 -shr 8))
}
$descriptor = [byte[]](0xA5, 0x5A, 0x05, 0x00, 0x00, 0x40, 0x81)
function New-Revolution([int]$n, [int]$seed) {
    for ($i = 0; $i -lt $n; $i++) {
        $ang = $i * 360.0 / $n
        $dist = if ($i % 7 -eq 3) { 0 } else { 150 + (($i * 97 + $seed * 31) % 11800) + 0.25 * ($i % 4) }   # includes 0 (no return) and >1000 mm
        [pscustomobject]@{ Angle = [math]::Round($ang * 64) / 64; Dist = $dist; Q = ($i + $seed) % 64; Start = ($i -eq 0) }
    }
}
function ConvertTo-Bytes($rev) { $l = New-Object 'System.Collections.Generic.List[byte]'; foreach ($n in $rev) { $l.AddRange([byte[]](New-Node $n.Angle $n.Dist $n.Q $n.Start)) }; , $l.ToArray() }

$N = 120
$revA = New-Revolution $N 1; $revB = New-Revolution $N 2; $revC = New-Revolution $N 3
$partial = New-Revolution $N 4 | Select-Object -First 50

# 1. Round trip: 3 complete revolutions + a partial one -> exactly 3 revolutions, every value exact
$stream = [byte[]]($descriptor + (ConvertTo-Bytes $revA) + (ConvertTo-Bytes $revB) + (ConvertTo-Bytes $revC) + (ConvertTo-Bytes $partial))
$r = ConvertFrom-RplidarScan -Bytes $stream
Assert-Equal $r.Revolutions.Count 3 'complete revolutions'
Assert-Equal $r.Stats.SkippedBytes 0 'no skipped bytes on clean data'
Assert-Equal $r.Stats.NodesInPartialLastRev 50 'partial revolution accounted for'
Assert-Equal $r.Stats.LeftoverBytes 0 'no leftover bytes'
$all = @($revA, $revB, $revC)
for ($k = 0; $k -lt 3; $k++) {
    Assert-Equal $r.Revolutions[$k].Count $N "rev $k node count"
    for ($i = 0; $i -lt $N; $i++) {
        $got = $r.Revolutions[$k][$i]; $exp = $all[$k][$i]
        Assert-Near $got.Angle $exp.Angle 0.0001 "rev $k node $i angle"
        Assert-Near $got.Distance $exp.Dist 0.0001 "rev $k node $i distance"
        Assert-Equal $got.Quality $exp.Q "rev $k node $i quality"
        Assert-Equal $got.Valid ($exp.Dist -gt 0) "rev $k node $i valid flag"
    }
}

# 2. Garbage before the descriptor is ignored
$r2 = ConvertFrom-RplidarScan -Bytes ([byte[]](@(0x11, 0x22, 0x33) + $stream))
Assert-Equal $r2.Revolutions.Count 3 'junk before descriptor'

# 3. Injected junk bytes mid-stream: decoder re-aligns, loses no real node, and reports exactly what it skipped
$a = ConvertTo-Bytes $revA; $b = ConvertTo-Bytes $revB; $c = ConvertTo-Bytes $revC
$cut = 5 * 40                                   # insert between node 39 and 40 of revolution B
$bCorrupt = [byte[]]($b[0..($cut - 1)] + @(0xFF, 0xFF, 0xFF) + $b[$cut..($b.Length - 1)])
$r3 = ConvertFrom-RplidarScan -Bytes ([byte[]]($descriptor + $a + $bCorrupt + $c + (ConvertTo-Bytes $partial)))
Assert-Equal $r3.Revolutions.Count 3 'revolutions after corruption'
Assert-Equal $r3.Stats.SkippedBytes 3 'skipped bytes equals injected bytes'
Assert-Equal $r3.Revolutions[1].Count $N 'corrupted revolution keeps all nodes'

# 4. Angle limits: 359.984 deg (q6 = 23039) accepted; q6 = 23040 (360 deg) rejected
$edgeOk = New-Node 359.984375 1000 10 $true
$q6Bad = 23040
$edgeBad = [byte[]]@(0x2D, ((($q6Bad -band 0x7F) -shl 1) -bor 1), ($q6Bad -shr 7), 0, 4)
$r4 = ConvertFrom-RplidarScan -Bytes ([byte[]]($descriptor + $edgeOk + $edgeOk + $edgeBad + (New-Node 0 500 5 $true)))
Assert-Equal $r4.Stats.SkippedBytes 5 'angle >= 360 rejected'

# 5. No descriptor -> clear error
$threw = $false; try { ConvertFrom-RplidarScan -Bytes ([byte[]](1..40)) | Out-Null } catch { $threw = $true }
Assert-Equal $threw $true 'missing descriptor throws'

# 6. CSV: values >= 1000 survive and decimals use '.', even under a comma-decimal culture
$old = [System.Threading.Thread]::CurrentThread.CurrentCulture
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
try {
    $nodes = @([pscustomobject]@{ Angle = 123.456; Distance = 12345.75; Quality = 33; Valid = $true },
               [pscustomobject]@{ Angle = 200.0; Distance = 0.0; Quality = 0; Valid = $false })
    $tmp = Join-Path $env:TEMP "rplidar_test_$([guid]::NewGuid().ToString('N')).csv"
    Export-RplidarCsv -Nodes $nodes -Path $tmp
    $rows = @(Import-Csv $tmp)
    Assert-Equal $rows.Count 1 'no-return node excluded by default'
    Assert-Equal $rows[0].dist_mm '12345.75' 'distance >= 1000 not split or reformatted'
    Assert-Equal $rows[0].angle_deg '123.456' 'decimal point under de-DE'
    Export-RplidarCsv -Nodes $nodes -Path $tmp -IncludeNoReturn
    Assert-Equal @(Import-Csv $tmp).Count 2 '-IncludeNoReturn keeps all nodes'
    Remove-Item $tmp -Force
}
finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $old }

# 7. Sweep selection prefers the revolution with most valid returns
$sparse = @($revA | ForEach-Object { [pscustomobject]@{ Angle = $_.Angle; Distance = 0; Quality = 0; Valid = $false } })
$dense = $r.Revolutions[0]
$pick = Select-RplidarSweep -Revolutions @($sparse, $dense)
Assert-Equal $pick.Index 1 'selects densest revolution'

Write-Host ("{0} checks passed, {1} failed" -f $script:passed, $script:failed) -ForegroundColor $(if ($script:failed) { 'Red' } else { 'Green' })
exit $(if ($script:failed) { 1 } else { 0 })
