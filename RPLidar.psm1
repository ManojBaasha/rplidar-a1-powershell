# RPLidar.psm1 - minimal driver for the Slamtec RPLidar A1 (standard SCAN mode) in plain PowerShell.
#
# Layers (each can be used and tested on its own):
#   Invoke-RplidarCapture      hardware  : spin the motor, record raw bytes, always stop the motor
#   ConvertFrom-RplidarScan    decoder   : raw bytes -> revolutions of nodes (pure function, no hardware)
#   Select-RplidarSweep        selection : pick one representative revolution
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
    $sp = New-Object System.IO.Ports.SerialPort $Port, 115200, 'None', 8, 'One'
    $sp.ReadBufferSize = 262144          # PowerShell is slow; a big buffer prevents overflow while we loop
    $ms = New-Object System.IO.MemoryStream
    $firstData = $null
    $sp.Open()
    try {
        $sp.DtrEnable = $false           # A1 adapter: DTR cleared = motor ON
        $sp.Write([byte[]](0xA5, 0x25), 0, 2)   # STOP, in case a previous scan is still streaming
        Start-Sleep -Milliseconds 100
        Start-Sleep -Seconds $SpinUpSeconds
        $sp.DiscardInBuffer()
        $sp.Write([byte[]](0xA5, 0x20), 0, 2)   # SCAN
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
    finally {
        try { $sp.Write([byte[]](0xA5, 0x25), 0, 2) } catch { Write-Warning "Could not send STOP: $($_.Exception.Message)" }
        $sp.DtrEnable = $true            # DTR set = motor OFF
        Start-Sleep -Milliseconds 200
        $sp.Close()
    }
    [pscustomobject]@{
        Bytes            = $ms.ToArray()
        FirstDataSeconds = $firstData
        ElapsedSeconds   = $elapsed
    }
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

    $d = $script:ScanDescriptor
    $start = -1
    for ($i = 0; $i -le $Bytes.Length - $d.Length; $i++) {
        $hit = $true
        for ($k = 0; $k -lt $d.Length; $k++) { if ($Bytes[$i + $k] -ne $d[$k]) { $hit = $false; break } }
        if ($hit) { $start = $i; break }
    }
    if ($start -lt 0) { throw 'Scan response descriptor (A5 5A 05 00 00 40 81) not found in data.' }

    $revs = New-Object 'System.Collections.Generic.List[object]'
    $cur = $null
    $skipped = 0; $nodesTotal = 0; $nodesBeforeFirstStart = 0
    $i = $start + $d.Length
    while ($i + 5 -le $Bytes.Length) {
        $b0 = [int]$Bytes[$i]; $b1 = [int]$Bytes[$i + 1]; $b2 = [int]$Bytes[$i + 2]
        $s = $b0 -band 1
        $notS = ($b0 -shr 1) -band 1
        $angleQ6 = ($b1 -shr 1) -bor ($b2 -shl 7)      # [int] casts matter: byte shifts would truncate
        if ($s -eq $notS -or ($b1 -band 1) -ne 1 -or $angleQ6 -ge 23040) { $skipped++; $i++; continue }

        if ($s -eq 1) {
            if ($null -ne $cur -and $cur.Count -gt 0) { $revs.Add($cur.ToArray()) }
            $cur = New-Object 'System.Collections.Generic.List[object]'
        }
        $distQ2 = [int]$Bytes[$i + 3] -bor ([int]$Bytes[$i + 4] -shl 8)
        $nodesTotal++
        if ($null -eq $cur) { $nodesBeforeFirstStart++ }
        else {
            $cur.Add([pscustomobject]@{
                Angle    = $angleQ6 / 64.0
                Distance = $distQ2 / 4.0
                Quality  = $b0 -shr 2
                Valid    = ($distQ2 -gt 0)
            })
        }
        $i += 5
    }
    $trailing = if ($null -ne $cur) { $cur.Count } else { 0 }   # nodes of the unfinished last revolution

    [pscustomobject]@{
        Revolutions = $revs.ToArray()
        Stats       = [pscustomobject]@{
            TotalBytes             = $Bytes.Length
            Nodes                  = $nodesTotal
            SkippedBytes           = $skipped
            LeftoverBytes          = $Bytes.Length - $i
            NodesBeforeFirstStart  = $nodesBeforeFirstStart
            NodesInPartialLastRev  = $trailing
            CompleteRevolutions    = $revs.Count
        }
    }
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

Export-ModuleMember -Function Invoke-RplidarCapture, ConvertFrom-RplidarScan, Select-RplidarSweep, Get-RplidarAudit, Export-RplidarCsv, Get-RplidarInfo
