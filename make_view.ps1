<#
.SYNOPSIS  Turn data\scan.csv into a self-contained top-down page, data\view.html (no external libraries).
.DESCRIPTION
  Picture convention: the sensor is the red dot, the top of the page is the sensor's 0 degree direction,
  angles increase clockwise, rings are 0.5 m apart. Only valid returns are drawn.
#>
[CmdletBinding()]
param(
    [string]$In,
    [string]$Out,
    [switch]$Open
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $In)  { $In  = Join-Path $PSScriptRoot 'data\scan.csv' }
if (-not $Out) { $Out = Join-Path $PSScriptRoot 'data\view.html' }

$inv = [System.Globalization.CultureInfo]::InvariantCulture
$rows = @(Import-Csv $In | Where-Object { $_.valid -eq '1' })
if ($rows.Count -eq 0) { throw "No valid points in $In." }
$points = ($rows | ForEach-Object { '[{0},{1}]' -f ([double]::Parse($_.angle_deg, $inv)).ToString('F2', $inv), ([double]::Parse($_.dist_mm, $inv)).ToString('F0', $inv) }) -join ','

$html = @'
<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Lidar view</title>
<style>body{margin:0;background:#0b0f14;color:#9fb3c8;font:14px system-ui}canvas{display:block;margin:auto}#i{position:fixed;left:12px;top:10px}</style>
<div id="i"></div><canvas id="c"></canvas>
<script>
const P=[__POINTS__];                       // [angle_deg, dist_mm], valid returns only
const c=document.getElementById('c'),x=c.getContext('2d');
const S=Math.max(300,Math.min(innerWidth,innerHeight)-20);c.width=c.height=S;
const maxd=P.reduce((m,p)=>Math.max(m,p[1]),0),R=Math.ceil(maxd/500)*500,k=(S/2-24)/R;
x.translate(S/2,S/2);x.strokeStyle='#1c2733';x.fillStyle='#4b6075';x.font='12px system-ui';
for(let r=500;r<=R;r+=500){x.beginPath();x.arc(0,0,r*k,0,7);x.stroke();x.fillText((r/1000)+' m',4,-r*k-3)}
x.beginPath();x.moveTo(-S/2,0);x.lineTo(S/2,0);x.moveTo(0,-S/2);x.lineTo(0,S/2);x.stroke();
x.fillStyle='#38e08c';
for(const[a,d]of P){const t=a*Math.PI/180;x.fillRect(d*Math.sin(t)*k-1.5,-d*Math.cos(t)*k-1.5,3,3)}   // clockwise from the top
x.fillStyle='#ff5a5a';x.beginPath();x.arc(0,0,4,0,7);x.fill();
document.getElementById('i').textContent=P.length+' valid returns, farthest '+(maxd/1000).toFixed(2)+' m. Red dot = sensor, top = 0 deg, clockwise.';
</script>
'@
Set-Content -Path $Out -Value $html.Replace('__POINTS__', $points) -Encoding utf8
"Wrote $Out ($($rows.Count) points)"
if ($Open) { Start-Process $Out }
