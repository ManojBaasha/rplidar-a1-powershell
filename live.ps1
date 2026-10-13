<#
.SYNOPSIS  Live top-down lidar view in your browser, served from this machine only (http://localhost:<port>/).
.DESCRIPTION
  Spins the motor, decodes the stream as it arrives and serves the newest revolution to a canvas page that
  redraws about 8 times a second. Press Ctrl+C in this window to stop; the motor is always switched off.
  Safety nets so the motor never spins forever: it stops after -MaxMinutes, and after -IdleSeconds without
  any request from a browser.
  -ReplayRaw plays a recording made by scan.ps1 -SaveRaw / audit.ps1 (data\raw.bin) at real speed instead of
  using the sensor, which is handy for testing without the motor.
.EXAMPLE   powershell -ExecutionPolicy Bypass -File live.ps1
.EXAMPLE   powershell -ExecutionPolicy Bypass -File live.ps1 -ReplayRaw data\raw.bin -MaxMinutes 1
.NOTES     The server binds to localhost only and rejects requests whose Host header is not localhost.
#>
[CmdletBinding()]
param(
    [string]$Port = 'COM3',
    [ValidateRange(1024, 65535)][int]$HttpPort = 8765,
    [ValidateRange(0.1, 120)][double]$MaxMinutes = 10,
    [ValidateRange(10, 3600)][int]$IdleSeconds = 120,
    [string]$ReplayRaw,
    [switch]$NoOpen
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RPLidar.psm1') -Force
$inv = [System.Globalization.CultureInfo]::InvariantCulture

$page = @'
<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Lidar live</title>
<style>
html,body{margin:0;height:100%;background:#0b0f14;color:#9fb3c8;font:14px system-ui;overflow:hidden}
canvas{display:block;width:100vw;height:100vh}
#bar{position:fixed;left:12px;top:10px;line-height:1.5}
button,select{background:#16202b;color:#9fb3c8;border:1px solid #2a3a4a;border-radius:6px;padding:3px 8px;font:inherit}
</style>
<canvas id="c"></canvas>
<div id="bar"><div id="info">connecting...</div>
<button id="pause">Pause</button> range <select id="range"><option value="0">auto</option><option>1</option><option>2</option><option>4</option><option>8</option><option>12</option></select> m</div>
<script>
const cv=document.getElementById('c'),x=cv.getContext('2d'),info=document.getElementById('info');
let revs=[],since=-1,paused=false,autoR=2,meta={};
document.getElementById('pause').onclick=e=>{paused=!paused;e.target.textContent=paused?'Resume':'Pause';draw()};
function draw(){
  const dpr=devicePixelRatio||1,W=cv.clientWidth,H=cv.clientHeight;
  if(cv.width!==W*dpr||cv.height!==H*dpr){cv.width=W*dpr;cv.height=H*dpr}
  x.setTransform(dpr,0,0,dpr,0,0);x.clearRect(0,0,W,H);
  const S=Math.min(W,H),sel=+document.getElementById('range').value;
  const maxd=revs.reduce((m,r)=>r.pts.reduce((a,p)=>Math.max(a,p[1]),m),0)/1000;
  autoR=Math.max(1,autoR*0.97,Math.ceil(maxd*2)/2);          // grows at once, shrinks slowly
  const R=(sel||autoR)*1000,k=(S/2-28)/R;
  x.translate(W/2,H/2);x.strokeStyle='#1c2733';x.fillStyle='#4b6075';x.font='12px system-ui';x.lineWidth=1;
  const step=R>6000?2000:R>2500?1000:500;
  for(let r=step;r<=R;r+=step){x.beginPath();x.arc(0,0,r*k,0,7);x.stroke();x.fillText((r/1000)+' m',4,-r*k-3)}
  x.beginPath();x.moveTo(-W/2,0);x.lineTo(W/2,0);x.moveTo(0,-H/2);x.lineTo(0,H/2);x.stroke();
  revs.forEach((r,i)=>{                                          // newest bright, older ones fade
    const a=(i+1)/revs.length;x.fillStyle='rgba(56,224,140,'+(0.12+0.88*a*a)+')';
    for(const[ang,d]of r.pts){if(d>R)continue;const t=ang*Math.PI/180;x.fillRect(d*Math.sin(t)*k-1.5,-d*Math.cos(t)*k-1.5,3,3)}
  });
  x.fillStyle='#ff5a5a';x.beginPath();x.arc(0,0,4,0,7);x.fill();
  x.fillStyle='#ff5a5a';x.beginPath();x.moveTo(0,-16);x.lineTo(-5,-8);x.lineTo(5,-8);x.fill();   // 0 deg marker
  const cur=revs[revs.length-1];
  info.textContent=cur?('rev '+meta.rev+'  '+cur.pts.length+' returns  '+meta.hz.toFixed(1)+' rev/s  skipped bytes '+meta.skipped+(paused?'  [paused]':'')):'waiting for data (the motor needs a few seconds)...';
}
async function poll(){
  try{
    if(!paused){
      const r=await fetch('/scan?since='+since,{cache:'no-store'});
      if(r.status===200){const j=await r.json();since=j.rev;meta=j;revs.push(j);if(revs.length>4)revs.shift();draw()}
    }
  }catch(e){info.textContent='server not reachable (stopped?)'}
  setTimeout(poll,110);
}
addEventListener('resize',draw);document.getElementById('range').onchange=draw;draw();poll();   // redraw only when something changed
</script>
'@
$pageBytes = [System.Text.Encoding]::UTF8.GetBytes($page)

# --- shared state ---
$latestRev = 0; $latestJson = $null
$stamps = New-Object 'System.Collections.Generic.Queue[double]'   # completion times of recent revolutions (for rev/s)
$clock = [System.Diagnostics.Stopwatch]::StartNew()
$lastRequest = [System.Diagnostics.Stopwatch]::StartNew()
$decoder = New-RplidarStreamDecoder

function Publish([object]$nodes) {
    $script:latestRev++
    $script:stamps.Enqueue($script:clock.Elapsed.TotalSeconds)
    while ($script:stamps.Count -gt 1 -and ($script:clock.Elapsed.TotalSeconds - $script:stamps.Peek()) -gt 3) { [void]$script:stamps.Dequeue() }
    $hz = if ($script:stamps.Count -gt 1) { ($script:stamps.Count - 1) / ($script:clock.Elapsed.TotalSeconds - $script:stamps.Peek()) } else { 0 }
    $sb = New-Object System.Text.StringBuilder
    foreach ($n in $nodes) { if ($n.Valid) { [void]$sb.Append('[').Append($n.Angle.ToString('F1', $inv)).Append(',').Append($n.Distance.ToString('F0', $inv)).Append('],') } }
    if ($sb.Length -gt 0) { $sb.Length-- }
    $skipped = (& $script:decoder.Stats).SkippedBytes
    $script:latestJson = '{{"rev":{0},"hz":{1},"skipped":{2},"pts":[{3}]}}' -f $script:latestRev, $hz.ToString('F2', $inv), $skipped, $sb.ToString()
}

function Send([System.Net.HttpListenerContext]$ctx, [int]$code, [string]$type, [byte[]]$body) {
    $res = $ctx.Response
    $res.StatusCode = $code
    $res.Headers['Cache-Control'] = 'no-store'
    if ($null -ne $body) { $res.ContentType = $type; $res.ContentLength64 = $body.Length; $res.OutputStream.Write($body, 0, $body.Length) }
    $res.Close()
}

# --- source: sensor or replay ---
$sp = $null; $replay = $null; $replayFed = 0L
if ($ReplayRaw) {
    $replay = [System.IO.File]::ReadAllBytes($ReplayRaw)
    if ($replay.Length -lt 1000) { throw "Replay file $ReplayRaw is too small." }
    $whole = 7 + 5 * [int][math]::Floor(($replay.Length - 7) / 5)       # whole nodes only, so looping keeps alignment
    if ($whole -lt $replay.Length) { $replay = $replay[0..($whole - 1)] }
    Write-Host "Replaying $ReplayRaw at real speed (no sensor used)."
}
else { Write-Host "Starting the lidar on $Port (motor spin-up about 3 s)..."; $sp = Start-RplidarScan -Port $Port }

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$HttpPort/")
$cpu0 = (Get-Process -Id $PID).TotalProcessorTime.TotalSeconds; $wall0 = $clock.Elapsed.TotalSeconds
try {
    try { $listener.Start() } catch { throw "Could not listen on http://localhost:$HttpPort/ ($($_.Exception.Message)). Try another -HttpPort." }
    $url = "http://localhost:$HttpPort/"
    Write-Host "Live view: $url   (Ctrl+C to stop; auto-stop after $MaxMinutes min or $IdleSeconds s without a browser)"
    if (-not $NoOpen) { Start-Process $url }
    $pending = $listener.GetContextAsync()
    $chunk = New-Object byte[] 8192
    $stopReason = $null
    while ($null -eq $stopReason) {
        $busy = $false
        # 1. bytes in
        if ($replay) {
            $due = [long]($clock.Elapsed.TotalSeconds * 9800) - $replayFed
            if ($due -ge 200) {
                $take = [int][math]::Min($due, 8192)
                $buf = New-Object byte[] $take
                for ($k = 0; $k -lt $take; ) {          # after the 7-byte header, loop the node stream (its length is a multiple of 5)
                    $p = if ($replayFed -lt $replay.Length) { [int]$replayFed } else { 7 + [int](($replayFed - 7) % ($replay.Length - 7)) }
                    $n = [math]::Min($take - $k, $replay.Length - $p)
                    [Array]::Copy($replay, $p, $buf, $k, $n); $k += $n; $replayFed += $n
                }
                & $decoder.Feed $buf; $busy = $true
            }
        }
        else {
            $n = $sp.BytesToRead
            if ($n -gt 0) { $n = $sp.Read($chunk, 0, [math]::Min($n, $chunk.Length)); $buf = New-Object byte[] $n; [Array]::Copy($chunk, $buf, $n); & $decoder.Feed $buf; $busy = $true }
        }
        $done = & $decoder.Take
        if ($done.Count -gt 0) { Publish $done[$done.Count - 1] }   # newest completed revolution; older ones are skipped if we fell behind

        # 2. HTTP
        if ($pending.IsCompleted) {
            $busy = $true
            try {
                $ctx = $pending.GetAwaiter().GetResult()
                $lastRequest.Restart()
                $hostOk = $ctx.Request.Headers['Host'] -match '^(localhost|127\.0\.0\.1)(:\d+)?$'
                $path = $ctx.Request.Url.AbsolutePath
                if (-not $hostOk) { Send $ctx 403 'text/plain' ([System.Text.Encoding]::ASCII.GetBytes('forbidden')) }
                elseif ($path -eq '/') { Send $ctx 200 'text/html; charset=utf-8' $pageBytes }
                elseif ($path -eq '/scan') {
                    $since = 0; [void][int]::TryParse($ctx.Request.QueryString['since'], [ref]$since)
                    if ($null -eq $latestJson -or $since -eq $latestRev) { Send $ctx 204 $null $null }
                    else { Send $ctx 200 'application/json' ([System.Text.Encoding]::UTF8.GetBytes($latestJson)) }
                }
                else { Send $ctx 404 'text/plain' ([System.Text.Encoding]::ASCII.GetBytes('not found')) }
            }
            catch { Write-Verbose "request failed: $($_.Exception.Message)" }
            $pending = $listener.GetContextAsync()
        }

        # 3. stop conditions
        if ($clock.Elapsed.TotalMinutes -ge $MaxMinutes) { $stopReason = "reached -MaxMinutes ($MaxMinutes)" }
        elseif ($lastRequest.Elapsed.TotalSeconds -ge $IdleSeconds) { $stopReason = "no browser request for $IdleSeconds s" }
        if (-not $busy) { Start-Sleep -Milliseconds 8 }
    }
    Write-Host "Stopping: $stopReason."
}
finally {
    $cpu = (Get-Process -Id $PID).TotalProcessorTime.TotalSeconds - $cpu0; $wall = $clock.Elapsed.TotalSeconds - $wall0
    if ($listener.IsListening) { $listener.Stop() }
    $listener.Close()
    if ($null -ne $sp) { Stop-RplidarScan -Port $sp; Write-Host 'Motor stopped, port closed.' }
    $s = & $decoder.Stats
    Write-Host ('Revolutions published: {0}, bytes skipped: {1}, average CPU use of this process: {2:F0} % of one core over {3:F0} s.' -f $latestRev, $s.SkippedBytes, (100 * $cpu / [math]::Max($wall, 0.001)), $wall)
}
