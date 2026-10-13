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

# 8. Fusion: 8 noisy revolutions of one still scene with ~28% random dropouts -> fused sweep tracks the truth
$rnd = New-Object System.Random 42
function Get-Truth([double]$a) { 2500 + 400 * [math]::Sin($a * [math]::PI / 90) }
$noisy = @(foreach ($k in 0..7) {
    , @(for ($a = $rnd.NextDouble() * 1.4; $a -lt 360; $a += 1.38) {
        $ok = $rnd.NextDouble() -gt 0.28
        $d = if ($ok) { (Get-Truth $a) + ($rnd.NextDouble() - 0.5) * 20 } else { 0 }
        [pscustomobject]@{ Angle = $a; Distance = $d; Quality = 15; Valid = $ok }
    })
})
$stray = [pscustomobject]@{ Angle = 10.5; Distance = 500; Quality = 15; Valid = $true }   # one stray echo in one revolution only
$noisy[0] = @($noisy[0]) + $stray
$fused = @(Merge-RplidarRevolutions -Revolutions $noisy -BinDeg 1 -MinSupport 3)
$worst = 0.0
foreach ($f in $fused) { $e = [math]::Abs($f.Distance - (Get-Truth $f.Angle)); if ($e -gt $worst) { $worst = $e } }
$singleValid = @($noisy[1] | Where-Object { $_.Valid }).Count
Assert-Equal ($worst -le 40) $true "fused distance within 40 mm of truth (worst $([math]::Round($worst,1)) mm)"
Assert-Equal ($fused.Count -gt 250) $true "fused sweep covers >250 bins (got $($fused.Count))"
Assert-Equal ($fused.Count -gt $singleValid) $true "fused sweep denser than a single revolution ($($fused.Count) vs $singleValid)"
Assert-Equal (@($fused | Where-Object { $_.Distance -lt 1000 }).Count) 0 'single stray echo rejected by MinSupport'
Assert-Equal (@($fused | Where-Object { $_.Support -lt 3 }).Count) 0 'every fused bin has support >= 3'

# 9. Nearest object: wall at 3000 mm, object at 1000 mm around 100 deg, one stray echo at 500 mm
function New-WallRev([scriptblock]$objectAt, [double]$objDist, [double]$strayAngle) {
    , @(for ($a = 0.0; $a -lt 360; $a += 1.4) {
        $inObj = & $objectAt $a
        $d = if ($inObj) { $objDist } else { 3000 }
        if ([math]::Abs($a - $strayAngle) -lt 0.7) { $d = 500 }
        [pscustomobject]@{ Angle = $a; Distance = $d; Quality = 15; Valid = $true }
    })
}
$rev9 = New-WallRev { param($a) $a -ge 96.5 -and $a -le 103.5 } 1000 250
$o = @(Find-RplidarNearestObject -Revolutions @(, $rev9))
Assert-Equal $o.Count 1 'object found in revolution'
Assert-Near $o[0].AngleDeg 100 1.5 'object angle'
Assert-Near $o[0].DistanceMm 1000 0.001 'object distance (stray 500 mm echo ignored)'
Assert-Equal ($o[0].Points -ge 4) $true 'object has several points'

# object straddling 0 degrees (356..4): circular mean must come out near 0/360, not 180
$rev9b = New-WallRev { param($a) $a -ge 357 -or $a -le 3 } 800 -1000
$o2 = @(Find-RplidarNearestObject -Revolutions @(, $rev9b))
$diff = [math]::Abs((($o2[0].AngleDeg - 0 + 540) % 360) - 180)
Assert-Equal ($diff -le 1.5) $true "object across 0 deg: angle $([math]::Round($o2[0].AngleDeg,2)) is within 1.5 deg of 0"
Assert-Near $o2[0].DistanceMm 800 0.001 'wrap-around object distance'

# no valid points -> no object, no error
$none = @(Find-RplidarNearestObject -Revolutions @(, @([pscustomobject]@{ Angle = 1; Distance = 0; Quality = 0; Valid = $false })))
Assert-Equal $none.Count 0 'no object when nothing is valid'

# 10. Streaming decoder: identical results however the bytes are chunked
function Invoke-Chunked([byte[]]$bytes, [int[]]$sizes) {
    $dec = New-RplidarStreamDecoder
    $pos = 0; $k = 0
    while ($pos -lt $bytes.Length) {
        $n = [math]::Min($sizes[$k % $sizes.Count], $bytes.Length - $pos); $k++
        $chunk = New-Object byte[] $n; [Array]::Copy($bytes, $pos, $chunk, 0, $n)
        & $dec.Feed $chunk; $pos += $n
    }
    $revs = & $dec.Take
    $second = & $dec.Take
    [pscustomobject]@{ Revs = $revs; SecondTake = $second; Stats = (& $dec.Stats) }
}
function Get-Sig($revs) { (@($revs | ForEach-Object { ($_ | ForEach-Object { '{0},{1},{2},{3}' -f $_.Angle, $_.Distance, $_.Quality, $_.Valid }) -join ';' })) -join '|' }
$refSig = Get-Sig $r.Revolutions
$randSizes = [int[]](1..60 | ForEach-Object { 1 + $rnd.Next(40) })
$chunkings = [ordered]@{ '1 byte' = @(1); '2 bytes' = @(2); '3 bytes' = @(3); '5 bytes' = @(5); '7 bytes' = @(7); '64 bytes' = @(64); 'irregular' = @(1,2,3,4,5,6,7,8,9,10,11,12,13); 'random' = $randSizes }
foreach ($name in $chunkings.Keys) {
    $c = Invoke-Chunked $stream $chunkings[$name]
    Assert-Equal $c.Revs.Count 3 "stream [$name]: revolution count"
    Assert-Equal (Get-Sig $c.Revs) $refSig "stream [$name]: identical to batch decode"
    Assert-Equal $c.SecondTake.Count 0 "stream [$name]: second Take is empty"
    Assert-Equal $c.Stats.SkippedBytes 0 "stream [$name]: nothing skipped"
    Assert-Equal $c.Stats.Nodes $r.Stats.Nodes "stream [$name]: node count"
    Assert-Equal $c.Stats.NodesInPartialLastRev 50 "stream [$name]: partial revolution"
}
# corruption and junk-before-descriptor survive chunking (descriptor split across chunks, junk dropped and counted)
$corrupt = [byte[]]($descriptor + (ConvertTo-Bytes $revA) + $bCorrupt + (ConvertTo-Bytes $revC) + (ConvertTo-Bytes $partial))
foreach ($sz in 1, 7, 33) {
    $cc = Invoke-Chunked $corrupt @($sz)
    Assert-Equal $cc.Stats.SkippedBytes 3 "stream corrupt [$sz-byte chunks]: exactly the 3 injected bytes skipped"
    Assert-Equal $cc.Revs.Count 3 "stream corrupt [$sz-byte chunks]: revolutions"
}
$junked = [byte[]](@(0x11, 0x22, 0x33, 0xA5, 0x5A) + $stream)    # junk that even looks like the start of a descriptor
$jj = Invoke-Chunked $junked @(1)
Assert-Equal $jj.Revs.Count 3 'stream: junk before descriptor, 1-byte chunks'
Assert-Equal $jj.Stats.PreDescriptorBytes 5 'stream: junk before descriptor is counted'
# incremental Take: revolutions appear as soon as they complete
$dec = New-RplidarStreamDecoder
& $dec.Feed ([byte[]]($descriptor + (ConvertTo-Bytes $revA) + (ConvertTo-Bytes $revB)[0..4]))
$t1 = & $dec.Take
Assert-Equal $t1.Count 1 'incremental: revolution A completes when the first node of B (start flag) arrives'
& $dec.Feed ([byte[]]((ConvertTo-Bytes $revB)[5..((ConvertTo-Bytes $revB).Length - 1)] + (ConvertTo-Bytes $revC)[0..4]))
$t2 = & $dec.Take
Assert-Equal $t2.Count 1 'incremental: revolution B completes when the first node of C arrives'

Write-Host ("{0} checks passed, {1} failed" -f $script:passed, $script:failed) -ForegroundColor $(if ($script:failed) { 'Red' } else { 'Green' })
exit $(if ($script:failed) { 1 } else { 0 })
