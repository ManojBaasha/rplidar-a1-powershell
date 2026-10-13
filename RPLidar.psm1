# RPLidar.psm1 - minimal driver for the Slamtec RPLidar A1 (standard SCAN mode) in plain PowerShell.
#
# Layers (each can be used and tested on its own):
#   Start-RplidarScan / Stop-RplidarScan   hardware: motor on + scan command / stop + motor off + close port
#   Invoke-RplidarCapture      hardware  : record raw bytes for N seconds (uses the two above, always stops the motor)
#   New-RplidarStreamDecoder   decoder   : incremental decoder for live data (chunk-size independent)
#   ConvertFrom-RplidarScan    decoder   : whole byte array -> revolutions of nodes (wraps the stream decoder)
#   Select-RplidarSweep        selection : pick one representative revolution
#   Merge-RplidarRevolutions   fusion    : median-merge many revolutions of a still scene into one denser sweep
#   Find-RplidarNearestObject  measuring : nearest object per revolution (angle, distance) for accuracy tests
#   Get-RplidarAudit           validation: integrity and repeatability statistics
#   Export-RplidarCsv          output    : culture-independent CSV
#
# Protocol reference (Slamtec RPLidar interface spec, standard scan):
#   request  A5 20                       response descriptor  A5 5A 05 00 00 40 81
#   then 5-byte nodes, repeated:
#     byte0  bits 7..2 quality, bit1 = NOT start flag, bit0 = start flag (1 = first node of a revolution)
#     byte1  bits 7..1 angle_q6 low 7 bits, bit0 = check bit (always 1)
#     byte2  angle_q6 high 8 bits          angle_deg = angle_q6 / 64, clockwise, 0 = sensor front
#     byte3,4 distance_q2 (little endian)  distance_mm = distance_q2 / 4, 0 = no valid return
#
# Sensor behaviour observed on a real A1 (see README, "Validation"):
#   - The angle of a no-return node (distance 0) is unreliable: it can run several degrees ahead, then jump back.
#     Angles of valid nodes strictly increase within a revolution, so geometry should use valid nodes only.
#   - The start flag fires about 8 degrees before the angle wraps to 0, so a revolution spans ~352 -> 350 degrees.
#   - Quality is a constant 15 for returns in this mode, so it carries no information here.

Set-StrictMode -Version Latest

$script:ScanDescriptor = [byte[]](0xA5, 0x5A, 0x05, 0x00, 0x00, 0x40, 0x81)
$script:Culture = [System.Globalization.CultureInfo]::InvariantCulture

function Start-RplidarScan {
    <#
    .SYNOPSIS  Open the port, spin the motor up and start a standard scan. Returns the open SerialPort.
    .DESCRIPTION
      The caller owns the port and MUST pass it to Stop-RplidarScan (use try/finally) so the motor is switched off.
      Data begins to arrive about 1 s after this returns.
    #>
    [CmdletBinding()]
    param(
        [string]$Port = 'COM3',
        [ValidateRange(0, 10)][int]$SpinUpSeconds = 3
    )
    $sp = New-Object System.IO.Ports.SerialPort $Port, 115200, 'None', 8, 'One'
    $sp.ReadBufferSize = 262144          # PowerShell is slow; a big buffer prevents overflow while we loop
    $sp.Open()
    try {
        $sp.DtrEnable = $false           # A1 adapter: DTR cleared = motor ON
        $sp.Write([byte[]](0xA5, 0x25), 0, 2)   # STOP, in case a previous scan is still streaming
        Start-Sleep -Milliseconds 100
        Start-Sleep -Seconds $SpinUpSeconds
        $sp.DiscardInBuffer()
        $sp.Write([byte[]](0xA5, 0x20), 0, 2)   # SCAN
    }
    catch { Stop-RplidarScan -Port $sp; throw }
    $sp
}

function Stop-RplidarScan {
    <#
    .SYNOPSIS  Stop the scan, switch the motor off and close the port. Safe to call on a closed port.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.IO.Ports.SerialPort]$Port)
    try {
        if ($Port.IsOpen) {
            try { $Port.Write([byte[]](0xA5, 0x25), 0, 2) } catch { Write-Warning "Could not send STOP: $($_.Exception.Message)" }
            $Port.DtrEnable = $true      # DTR set = motor OFF
            Start-Sleep -Milliseconds 200
        }
    }
    finally { $Port.Close(); $Port.Dispose() }
}

function Invoke-RplidarCapture {
    <#
    .SYNOPSIS  Record raw scan bytes from the lidar. The motor is stopped even if capture fails.
    .OUTPUTS   Object with Bytes (byte[]), FirstDataSeconds and ElapsedSeconds.
    #>
    [CmdletBinding()]
    param(
        [string]$Port = 'COM3',
        [ValidateRange(1, 30)][int]$Seconds = 4,
        [ValidateRange(0, 10)][int]$SpinUpSeconds = 3
    )
    $ms = New-Object System.IO.MemoryStream
    $firstData = $null
    $sp = Start-RplidarScan -Port $Port -SpinUpSeconds $SpinUpSeconds
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $chunk = New-Object byte[] 8192
        while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
            $n = $sp.BytesToRead
            if ($n -le 0) { Start-Sleep -Milliseconds 15; continue }
            $n = $sp.Read($chunk, 0, [Math]::Min($n, $chunk.Length))
            $ms.Write($chunk, 0, $n)
            if ($null -eq $firstData -and $ms.Length -gt $script:ScanDescriptor.Length) { $firstData = $sw.Elapsed.TotalSeconds }
        }
        $elapsed = $sw.Elapsed.TotalSeconds
    }
    finally { Stop-RplidarScan -Port $sp }
    [pscustomobject]@{
        Bytes            = $ms.ToArray()
        FirstDataSeconds = $firstData
        ElapsedSeconds   = $elapsed
    }
}

function New-RplidarStreamDecoder {
    <#
    .SYNOPSIS  Incremental decoder: feed raw bytes in chunks of any size, collect completed revolutions as they finish.
    .DESCRIPTION
      Returns an object with three scriptblocks (call with &):
        Feed  <byte[]>   add bytes
        Take             returns the array of revolutions completed since the last Take (node arrays, as ConvertFrom-RplidarScan)
        Stats            decoder counters
      Node validation and re-alignment are described at ConvertFrom-RplidarScan. The result does not depend on how
      the bytes are chunked (tests.ps1 checks this with 1-byte, odd and random chunk sizes).
      Bytes before the response descriptor are dropped and counted in PreDescriptorBytes.
    #>
    [CmdletBinding()]
    param()
    $st = [pscustomobject]@{
        Buf = New-Object 'System.Collections.Generic.List[byte]'
        Found = $false; Cur = $null
        Done = New-Object 'System.Collections.Generic.List[object]'
        Fed = 0; Pre = 0; Skipped = 0; Nodes = 0; Before = 0; Revs = 0
    }
    $desc = $script:ScanDescriptor

    $feed = {
        param([byte[]]$Bytes)
        $st.Fed += $Bytes.Length
        $b = $st.Buf
        $b.AddRange($Bytes)
        $i = 0
        if (-not $st.Found) {
            $hit = -1
            for ($p = 0; $p -le $b.Count - $desc.Length; $p++) {
                $m = $true
                for ($k = 0; $k -lt $desc.Length; $k++) { if ($b[$p + $k] -ne $desc[$k]) { $m = $false; break } }
                if ($m) { $hit = $p; break }
            }
            if ($hit -lt 0) {      # keep a possible partial descriptor at the end, drop the rest
                $drop = $b.Count - [math]::Min($desc.Length - 1, $b.Count)
                if ($drop -gt 0) { $b.RemoveRange(0, $drop); $st.Pre += $drop }
                return
            }
            $st.Pre += $hit; $st.Found = $true; $i = $hit + $desc.Length
        }
        while ($i + 5 -le $b.Count) {
            $b0 = [int]$b[$i]; $b1 = [int]$b[$i + 1]; $b2 = [int]$b[$i + 2]
            $s = $b0 -band 1
            $notS = ($b0 -shr 1) -band 1
            $angleQ6 = ($b1 -shr 1) -bor ($b2 -shl 7)      # [int] casts matter: byte shifts would truncate
            if ($s -eq $notS -or ($b1 -band 1) -ne 1 -or $angleQ6 -ge 23040) { $st.Skipped++; $i++; continue }
            if ($s -eq 1) {
                if ($null -ne $st.Cur -and $st.Cur.Count -gt 0) { $st.Done.Add($st.Cur.ToArray()); $st.Revs++ }
                $st.Cur = New-Object 'System.Collections.Generic.List[object]'
            }
            $distQ2 = [int]$b[$i + 3] -bor ([int]$b[$i + 4] -shl 8)
            $st.Nodes++
            if ($null -eq $st.Cur) { $st.Before++ }
            else {
                $st.Cur.Add([pscustomobject]@{
                    Angle    = $angleQ6 / 64.0
                    Distance = $distQ2 / 4.0
                    Quality  = $b0 -shr 2
                    Valid    = ($distQ2 -gt 0)
                })
            }
            $i += 5
        }
        if ($i -gt 0) { $b.RemoveRange(0, $i) }
    }.GetNewClosure()

    $take = { $a = $st.Done.ToArray(); $st.Done.Clear(); , $a }.GetNewClosure()

    $stats = {
        [pscustomobject]@{
            DescriptorFound       = $st.Found
            TotalBytes            = $st.Fed
            PreDescriptorBytes    = $st.Pre
            Nodes                 = $st.Nodes
            SkippedBytes          = $st.Skipped
            LeftoverBytes         = $(if ($st.Found) { $st.Buf.Count } else { 0 })
            NodesBeforeFirstStart = $st.Before
            NodesInPartialLastRev = $(if ($null -ne $st.Cur) { $st.Cur.Count } else { 0 })
            CompleteRevolutions   = $st.Revs
        }
    }.GetNewClosure()

    [pscustomobject]@{ Feed = $feed; Take = $take; Stats = $stats }
}

function ConvertFrom-RplidarScan {
    <#
    .SYNOPSIS  Decode a raw standard-scan byte stream into revolutions. Pure function: no hardware needed.
    .DESCRIPTION
      Locates the response descriptor, then reads 5-byte nodes. A node must pass the protocol's own
      checks (start/!start bits differ, check bit set, angle < 360). If a node fails the checks one
      byte is skipped to re-align (counted in Stats.SkippedBytes, so data loss is visible, not silent).
      Only complete revolutions are returned: data before the first start flag and after the last
      one is partial and is excluded (counted in Stats).
    .OUTPUTS   Object with Revolutions (array of node arrays) and Stats.
               Node = Angle (deg), Distance (mm), Quality (0-63), Valid (distance > 0).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $dec = New-RplidarStreamDecoder
    & $dec.Feed $Bytes
    $stats = & $dec.Stats
    if (-not $stats.DescriptorFound) { throw 'Scan response descriptor (A5 5A 05 00 00 40 81) not found in data.' }
    $revs = & $dec.Take
    [pscustomobject]@{ Revolutions = $revs; Stats = $stats }
}

function Select-RplidarSweep {
    <#
    .SYNOPSIS  Pick the complete revolution with the most valid returns (most complete picture).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Revolutions)
    if ($Revolutions.Count -eq 0) { throw 'No complete revolutions to choose from.' }
    $best = 0; $bestValid = -1
    for ($r = 0; $r -lt $Revolutions.Count; $r++) {
        $v = @($Revolutions[$r] | Where-Object { $_.Valid }).Count
        if ($v -gt $bestValid) { $best = $r; $bestValid = $v }
    }
    [pscustomobject]@{ Index = $best; Nodes = $Revolutions[$best] }
}

function Get-RplidarAudit {
    <#
    .SYNOPSIS  Integrity and repeatability statistics for a decoded capture.
    .DESCRIPTION
      Integrity     : Decoded.Stats (bytes skipped while re-aligning; any > 0 means bytes were lost or corrupted).
      Geometry      : measured on VALID nodes only. The angle the A1 reports for a no-return node (distance 0)
                      is unreliable (it can run several degrees ahead and then jump back), so those nodes are
                      excluded. Per revolution: Wraps (360 -> 0 crossings, expected exactly 1), BackwardSteps
                      (angle decreasing without a wrap, expected 0), MaxGapDeg and Holes (steps larger than
                      HoleDeg between consecutive valid returns = angular regions with no detection).
      Repeatability : angles are grouped into BinDeg-wide bins (use a width of at least ~2 sample spacings).
                      A bin is "valid" in a revolution if it holds at least one valid return. Assumes the scene
                      and the sensor were still during the capture.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Decoded,
        [double]$ElapsedSeconds,
        [double]$FirstDataSeconds,
        [ValidateRange(0.5, 30)][double]$BinDeg = 3,
        [ValidateRange(1, 30)][double]$HoleDeg = 3
    )
    $revs = $Decoded.Revolutions
    $revCount = $revs.Count
    $nb = [int][math]::Ceiling(360 / $BinDeg)

    $perRev = New-Object 'System.Collections.Generic.List[object]'
    $binSum = @{}                    # bin -> list of per-revolution mean distances (one entry per revolution that was valid)
    foreach ($rev in $revs) {
        $v = @($rev | Where-Object { $_.Valid })
        $backward = 0; $wraps = 0; $maxGap = 0.0; $holes = 0
        for ($k = 1; $k -lt $v.Count; $k++) {
            $delta = $v[$k].Angle - $v[$k - 1].Angle
            if ($delta -lt -180) { $wraps++ }
            elseif ($delta -lt 0) { $backward++ }
            else {
                if ($delta -gt $maxGap) { $maxGap = $delta }
                if ($delta -gt $HoleDeg) { $holes++ }
            }
        }
        $perRev.Add([pscustomobject]@{
            Nodes = $rev.Count; Valid = $v.Count; NoReturn = $rev.Count - $v.Count
            Wraps = $wraps; BackwardSteps = $backward; MaxGapDeg = [math]::Round($maxGap, 1); Holes = $holes
            FirstAngle = [math]::Round($rev[0].Angle, 1)
        })

        $inBin = @{}
        foreach ($n in $v) {
            $b = [int][math]::Floor($n.Angle / $BinDeg)
            if (-not $inBin.ContainsKey($b)) { $inBin[$b] = New-Object 'System.Collections.Generic.List[double]' }
            $inBin[$b].Add($n.Distance)
        }
        foreach ($b in $inBin.Keys) {
            if (-not $binSum.ContainsKey($b)) { $binSum[$b] = New-Object 'System.Collections.Generic.List[double]' }
            $binSum[$b].Add(($inBin[$b] | Measure-Object -Average).Average)
        }
    }

    $persistent = 0; $intermittent = 0; $never = 0; $validCells = 0; $spreads = New-Object 'System.Collections.Generic.List[double]'
    for ($b = 0; $b -lt $nb; $b++) {
        $c = if ($binSum.ContainsKey($b)) { $binSum[$b].Count } else { 0 }
        $validCells += $c
        if ($c -eq 0) { $never++ } elseif ($c -ge 0.9 * $revCount) { $persistent++ } else { $intermittent++ }
        if ($c -ge 2) { $m = $binSum[$b] | Measure-Object -Minimum -Maximum; $spreads.Add($m.Maximum - $m.Minimum) }
    }
    $sorted = @($spreads | Sort-Object)
    $pick = { param($p) if ($sorted.Count) { $sorted[[int][math]::Floor(($sorted.Count - 1) * $p)] } else { $null } }

    $rate = $null
    if ($ElapsedSeconds -and $FirstDataSeconds) {
        $dt = $ElapsedSeconds - $FirstDataSeconds
        if ($dt -gt 0) { $rate = [pscustomobject]@{ NodesPerSec = [math]::Round($Decoded.Stats.Nodes / $dt); RevsPerSec = [math]::Round($revCount / $dt, 2) } }
    }

    [pscustomobject]@{
        Stats            = $Decoded.Stats
        PerRevolution    = $perRev.ToArray()
        Bins             = [pscustomobject]@{
            BinDeg = $BinDeg; Count = $nb; Revolutions = $revCount
            Persistent = $persistent; Intermittent = $intermittent; Never = $never
            ValidFraction = [math]::Round($validCells / ($nb * [math]::Max($revCount, 1)), 3)
        }
        DistanceSpreadMm = [pscustomobject]@{ Median = (& $pick 0.5); P90 = (& $pick 0.9); BinsCompared = $sorted.Count }
        Rate             = $rate
    }
}

function Merge-RplidarRevolutions {
    <#
    .SYNOPSIS  Fuse several revolutions of a still scene into one denser, less noisy sweep.
    .DESCRIPTION
      Valid returns are grouped into BinDeg-wide angle bins. A bin is kept if at least MinSupport DIFFERENT
      revolutions contributed to it (a single stray echo is discarded). The output node per bin has the median
      distance and mean angle of its samples. Quality holds the support count (capped at 63); Support and
      SpreadMm (max - min distance in the bin) are extra properties so noisy bins can be spotted.
      Only valid for a still sensor and scene: moving objects smear across revolutions.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Revolutions,
        [ValidateRange(0.1, 10)][double]$BinDeg = 1,
        [ValidateRange(1, 1000)][int]$MinSupport = 3
    )
    $angles = @{}; $dists = @{}; $lastRev = @{}; $support = @{}
    for ($r = 0; $r -lt $Revolutions.Count; $r++) {
        foreach ($n in $Revolutions[$r]) {
            if (-not $n.Valid) { continue }
            $b = [int][math]::Floor($n.Angle / $BinDeg)
            if (-not $angles.ContainsKey($b)) {
                $angles[$b] = New-Object 'System.Collections.Generic.List[double]'
                $dists[$b] = New-Object 'System.Collections.Generic.List[double]'
                $support[$b] = 0; $lastRev[$b] = -1
            }
            $angles[$b].Add($n.Angle); $dists[$b].Add($n.Distance)
            if ($lastRev[$b] -ne $r) { $lastRev[$b] = $r; $support[$b]++ }
        }
    }
    foreach ($b in ($angles.Keys | Sort-Object)) {
        if ($support[$b] -lt $MinSupport) { continue }
        $d = @($dists[$b] | Sort-Object)
        $mid = [int][math]::Floor(($d.Count - 1) / 2)
        $median = if ($d.Count % 2) { $d[$mid] } else { ($d[$mid] + $d[$mid + 1]) / 2 }
        [pscustomobject]@{
            Angle    = ($angles[$b] | Measure-Object -Average).Average
            Distance = $median
            Quality  = [math]::Min($support[$b], 63)
            Valid    = $true
            Support  = $support[$b]
            SpreadMm = $d[-1] - $d[0]
        }
    }
}

function Find-RplidarNearestObject {
    <#
    .SYNOPSIS  In each revolution, find the nearest solid object (a cluster of neighbouring valid returns at a similar distance).
    .DESCRIPTION
      Candidates are tried nearest first. A cluster grows from the seed point to angular neighbours (circularly,
      so an object straddling 0 degrees works) while consecutive points are at most MaxStepDeg apart and within
      DepthToleranceMm of the seed distance. The first cluster with at least MinPoints points wins, so a lone
      stray echo is ignored. Returns one row per revolution that contains such an object:
      AngleDeg (circular mean, 0-360), DistanceMm (median), Points, WidthDeg.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Revolutions,
        [double]$MinRangeMm = 150,
        [double]$DepthToleranceMm = 100,
        [double]$MaxStepDeg = 3,
        [int]$MinPoints = 3
    )
    for ($r = 0; $r -lt $Revolutions.Count; $r++) {
        $v = @($Revolutions[$r] | Where-Object { $_.Valid -and $_.Distance -ge $MinRangeMm } | Sort-Object Angle)
        $n = $v.Count
        if ($n -lt $MinPoints) { continue }
        $order = 0..($n - 1) | Sort-Object { $v[$_].Distance }
        $found = $null
        foreach ($seed in $order) {
            $members = New-Object 'System.Collections.Generic.List[int]'
            $members.Add($seed)
            $j = $seed
            while ($members.Count -lt $n) {          # grow towards increasing angle
                $nx = ($j + 1) % $n
                $step = ($v[$nx].Angle - $v[$j].Angle + 360) % 360
                if ($nx -eq $seed -or $step -gt $MaxStepDeg -or [math]::Abs($v[$nx].Distance - $v[$seed].Distance) -gt $DepthToleranceMm) { break }
                $members.Add($nx); $j = $nx
            }
            $j = $seed
            while ($members.Count -lt $n) {          # grow towards decreasing angle
                $pv = ($j - 1 + $n) % $n
                $step = ($v[$j].Angle - $v[$pv].Angle + 360) % 360
                if ($members.Contains($pv) -or $step -gt $MaxStepDeg -or [math]::Abs($v[$pv].Distance - $v[$seed].Distance) -gt $DepthToleranceMm) { break }
                $members.Add($pv); $j = $pv
            }
            if ($members.Count -ge $MinPoints) { $found = $members; break }
        }
        if ($null -eq $found) { continue }
        $sx = 0.0; $sy = 0.0; $dist = New-Object 'System.Collections.Generic.List[double]'
        foreach ($m in $found) { $t = $v[$m].Angle * [math]::PI / 180; $sx += [math]::Sin($t); $sy += [math]::Cos($t); $dist.Add($v[$m].Distance) }
        $ang = ([math]::Atan2($sx, $sy) * 180 / [math]::PI + 360) % 360
        $ds = @($dist | Sort-Object)
        $med = if ($ds.Count % 2) { $ds[[int][math]::Floor($ds.Count / 2)] } else { ($ds[$ds.Count / 2 - 1] + $ds[$ds.Count / 2]) / 2 }
        $angs = @($found | ForEach-Object { $v[$_].Angle })
        $rel = @($angs | ForEach-Object { (($_ - $ang + 540) % 360) - 180 })      # angles relative to the centroid, -180..180
        $width = ($rel | Measure-Object -Maximum).Maximum - ($rel | Measure-Object -Minimum).Minimum
        [pscustomobject]@{ Revolution = $r + 1; AngleDeg = $ang; DistanceMm = $med; Points = $found.Count; WidthDeg = $width }
    }
}

function Export-RplidarCsv {
    <#
    .SYNOPSIS  Write nodes as CSV with '.' decimals and no thousands separators, whatever the Windows locale.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Nodes,
        [Parameter(Mandatory)][string]$Path,
        [switch]$IncludeNoReturn
    )
    $c = $script:Culture
    $lines = foreach ($n in ($Nodes | Sort-Object Angle)) {   # sweeps start near 352 deg; sorted output is easier to use
        if (-not $n.Valid -and -not $IncludeNoReturn) { continue }
        '{0},{1},{2},{3}' -f $n.Angle.ToString('F3', $c), $n.Distance.ToString('F2', $c), $n.Quality, [int]$n.Valid
    }
    Set-Content -Path $Path -Value (@('angle_deg,dist_mm,quality,valid') + $lines) -Encoding ascii
}

function Get-RplidarInfo {
    <#
    .SYNOPSIS  Read-only query of device info and health (does not start the motor or scanning).
    #>
    [CmdletBinding()]
    param([string]$Port = 'COM3')
    $sp = New-Object System.IO.Ports.SerialPort $Port, 115200, 'None', 8, 'One'
    $sp.ReadTimeout = 1000
    $sp.Open()
    try {
        $sp.DtrEnable = $true             # motor off
        $ask = {
            param($cmd, $payloadLen)
            $sp.DiscardInBuffer()
            $sp.Write([byte[]](0xA5, $cmd), 0, 2)
            $need = 7 + $payloadLen; $buf = New-Object byte[] $need; $got = 0
            while ($got -lt $need) { $got += $sp.Read($buf, $got, $need - $got) }
            if ($buf[0] -ne 0xA5 -or $buf[1] -ne 0x5A) { throw 'Bad response descriptor.' }
            , $buf[7..($need - 1)]
        }
        $info = & $ask 0x50 20
        $health = & $ask 0x52 3
        [pscustomobject]@{
            ModelId  = '0x{0:X2}' -f $info[0]
            Firmware = '{0}.{1:D2}' -f $info[2], $info[1]
            Hardware = $info[3]
            Serial   = -join ($info[4..19] | ForEach-Object { '{0:X2}' -f $_ })
            Health   = @('Good', 'Warning', 'Error')[[math]::Min($health[0], 2)]
            ErrorCode = $health[1] + 256 * $health[2]
        }
    }
    finally { $sp.Close() }
}

Export-ModuleMember -Function Start-RplidarScan, Stop-RplidarScan, Invoke-RplidarCapture, New-RplidarStreamDecoder, ConvertFrom-RplidarScan, Select-RplidarSweep, Merge-RplidarRevolutions, Find-RplidarNearestObject, Get-RplidarAudit, Export-RplidarCsv, Get-RplidarInfo
