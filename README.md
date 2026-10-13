# rplidar-a1-powershell

Talk to a **Slamtec RPLidar A1** from Windows with nothing but PowerShell 5.1: no Python, no SDK, no
installs beyond the USB driver. Capture raw scan data, decode it, check it is trustworthy, export CSV and draw
a top-down view of the room.

Built on a slow laptop (2-core i3, 8 GB), so the code is deliberately light.

## Status

| Step | State |
|---|---|
| 1. Identify the device, install the driver, talk to it | done |
| 2. Capture + decode + CSV + top-down view | done, validated (see below) |
| 3. Live view (continuous redraw) | planned |
| 4. Mapping / SLAM (move the sensor, build a floor plan) | planned |
| Accuracy test against a tape measure | **todo** (needed before trusting absolute distances) |

## Hardware

- Slamtec RPLidar **A1M8**, on its USB adapter board (Silicon Labs **CP2102** USB-to-UART bridge, `VID_10C4 PID_EA60`).
- Serial: **115200 baud, 8N1**. Motor is switched by the **DTR** line: DTR cleared = motor on, DTR set = motor off.
- Needs 5 V at roughly 400-500 mA. A weak USB port or thin cable can stall the motor.

## Setup (Windows)

1. Plug in the lidar. If Device Manager shows "CP2102 USB to UART Bridge Controller" with **problem code 28**
   (`CM_PROB_FAILED_INSTALL`), the driver is missing.
2. Download the **CP210x Universal Windows Driver** from Silicon Labs
   (<https://www.silabs.com/developer-tools/usb-to-uart-bridge-vcp-drivers>). Scripted downloads get HTTP 403, use a browser.
3. Unzip, then install from an **elevated** prompt: `pnputil /add-driver silabser.inf /install`.
   (The driver binaries are signed by Silicon Laboratories and the catalog by Microsoft.)
4. A COM port appears (here `COM3`). Check with `Get-CimInstance Win32_SerialPort`.

## Usage

```powershell
powershell -ExecutionPolicy Bypass -File scan.ps1                 # one sweep -> data\scan.csv
powershell -ExecutionPolicy Bypass -File make_view.ps1 -Open      # data\scan.csv -> data\view.html
powershell -ExecutionPolicy Bypass -File audit.ps1                # 8 s capture + integrity/repeatability report
powershell -ExecutionPolicy Bypass -File audit.ps1 -RawPath data\raw.bin   # re-analyse a saved capture offline
powershell -ExecutionPolicy Bypass -File tests.ps1                # decoder tests, no hardware needed
```

Use `-Port COMx` if the lidar is not on COM3. All output goes to `data\`, which is git-ignored because a scan is
a map of your room.

In your own scripts:

```powershell
Import-Module .\RPLidar.psm1
$cap   = Invoke-RplidarCapture -Port COM3 -Seconds 4     # motor on, record raw bytes, motor off (always)
$dec   = ConvertFrom-RplidarScan -Bytes $cap.Bytes       # .Revolutions (arrays of nodes) and .Stats
$sweep = Select-RplidarSweep -Revolutions $dec.Revolutions
Export-RplidarCsv -Nodes $sweep.Nodes -Path scan.csv
Get-RplidarInfo -Port COM3                               # read-only: model, firmware, serial, health
```

## Files

| File | Purpose |
|---|---|
| `RPLidar.psm1` | The driver: capture, decoder, sweep selection, audit, CSV export, device info |
| `scan.ps1` | One sweep to CSV |
| `make_view.ps1` | CSV to a self-contained HTML top-down view |
| `audit.ps1` | Integrity and repeatability report with PASS/FAIL checks |
| `tests.ps1` | 1,458 hardware-free checks of the decoder and CSV writer |

## How it works

Standard scan protocol: send `A5 20`, receive the 7-byte descriptor `A5 5A 05 00 00 40 81`, then an endless stream
of 5-byte nodes.

| Byte | Content |
|---|---|
| 0 | bits 7..2 quality, bit 1 = NOT start flag, bit 0 = start flag (first node of a revolution) |
| 1 | bits 7..1 = angle_q6 low 7 bits, bit 0 = check bit (always 1) |
| 2 | angle_q6 high 8 bits. angle = q6 / 64 degrees, clockwise, 0 = front |
| 3-4 | distance_q2, little endian. distance = q2 / 4 mm. **0 means no return** |

The decoder validates every node (start and !start bits differ, check bit set, angle < 360). A node that fails is
skipped one byte at a time to re-align, and the count is reported, so lost data can never be silent.

Capture records raw bytes into memory first and decodes afterwards. Decoding while reading is too slow in
PowerShell and overflows the serial buffer.

## Validation

Hardware-free (`tests.ps1`, 1,458 checks): exact round trip of angle, distance and quality for every node of
synthetic revolutions (including values above 1000 mm and zero-distance nodes), partial-revolution handling,
junk before the descriptor, junk injected mid-stream (exactly the injected bytes are reported skipped, no real node
lost), angle limits (359.984 accepted, 360 rejected), CSV correctness under a comma-decimal locale (de-DE).

Real sensor (`audit.ps1`, 50 revolutions, still room):

| Check | Result |
|---|---|
| Bytes captured vs decoded | 66,872 = 7 + 5 x 13,373, **0 skipped, 0 leftover** |
| Throughput | about 1,950 nodes/s, about 7.3 revolutions/s, about 260 nodes per revolution |
| Valid angles going backwards within a revolution | **0** in all 50 revolutions |
| 360 to 0 wrap | exactly once per revolution, 50 of 50 |
| Valid returns per revolution | 178-195 of about 260 nodes |
| Bins (3 degrees) with a return in 90 percent or more of revolutions | 85 of 120; 30 intermittent; 5 never |
| Distance spread per bin across revolutions | median about 16 mm, 90th percentile about 69 mm (upper bound) |

Conclusion: the capture path is lossless. Missing dots are the sensor reporting "no echo", not data loss.

## Known sensor behaviour (found the hard way)

- **No-return nodes have unreliable angles.** A node with distance 0 can be reported several degrees ahead of its
  true position and then the angle jumps back. All 684 backward angle steps in the test capture involved a
  no-return node. Geometry uses valid nodes only; CSV export drops no-return nodes unless `-IncludeNoReturn`.
- **A revolution starts at about 352 degrees,** because the start flag fires before the angle wraps to 0. Exported
  sweeps are sorted by angle.
- **Quality is constant (15)** for returns in this mode, so it carries no information.
- **Data starts about 1 s after the scan command** and the motor needs about 3 s to spin up.
- **About 28 percent of nodes are no-return** in an ordinary room (glass, black or shiny surfaces, too far, too close).
- Motor speed cannot be tuned through DTR (on/off only), so rotation is about 7.3 Hz here.

## PowerShell 5.1 pitfalls hit during development

- `[byte] -shl 8` truncates. Cast to `[int]` before shifting.
- `$list -ne $null` filters a collection instead of comparing. Use `$null -ne $list`.
- `-f` with `N1` inserts thousands separators and uses the current culture: `3,172.0` broke the CSV. Use `ToString('F1', InvariantCulture)`.
- `$PSScriptRoot` is empty inside a `param()` default. Set defaults in the script body.
- A function returning `[byte[]]` is unrolled to `object[]`. Cast the result back.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Problem code 28 | No driver. See Setup |
| Port opens, scan command answered with only the 7-byte descriptor | Wait about 3 s for the motor, check DTR is cleared, check power |
| Motor spins but no data | Wait about 1 s after the scan command; try a powered USB hub |
| `skipped bytes > 0` in the audit | Cable or power problem, or the PC is too busy: close other programs, retry |

## Roadmap

1. Tape-measure accuracy test (known distance straight ahead, and known angle).
2. Fuse several revolutions into one denser sweep (median per angle bin).
3. Live view with a light redraw loop.
4. Scan matching / mapping while moving the sensor.

## License

MIT, see `LICENSE`.
