<#
 stadia-bt.ps1 - switch a Stadia controller to Bluetooth mode on Windows
 Uses GaryOderNichts' open-source stadiatool (github.com/GaryOderNichts/StadiaController)

 Run (normal, non-admin PowerShell):
   powershell -ExecutionPolicy Bypass -File .\stadia-bt.ps1

 Firmware sources, tried in order:
   1. Google's original URLs (probably dead)
   2. Docker image cuteminded/stadiabluetooth (community mirror; needs Docker Desktop)
   3. A folder you point at:  $env:STADIA_FILES = "C:\path\to\folder"
#>
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Work        = Join-Path $env:LOCALAPPDATA 'stadia-bt'
$RepoZip     = Join-Path $Work 'repo.zip'
$Repo        = Join-Path $Work 'StadiaController-main'
$Tool        = Join-Path $Repo 'stadiatool'
$Venv        = Join-Path $Work 'venv'
$VenvPy      = Join-Path $Venv 'Scripts\python.exe'
$Data        = Join-Path $Work 'data'
$GoogleBase  = 'https://stadia.google.com/controller/data'
$DockerImage = 'cuteminded/stadiabluetooth'
$Files       = @('bruce_pvt_a_prod_signed.bin','flashloader_fcb_get_vendor_id.bin','flashloader_fcb_w25q128jw.bin','restricted_ivt_flashloader.bin')

function Say($m)  { Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[ok] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!]  $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "[x]  $m" -ForegroundColor Red; exit 1 }
function Pause-Step($m = 'Press Enter when ready') { [void](Read-Host "     $m") }

function Test-Usb([string]$Vid) {
    $d = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
         Where-Object { $_.InstanceId -match "USB\\VID_$Vid" }
    return [bool]$d
}
function Wait-Usb([string]$Vid, [int]$Seconds) {
    for ($i = 0; $i -lt $Seconds * 2; $i++) {
        if (Test-Usb $Vid) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}
function Have-AllFiles { foreach ($f in $Files) { if (-not (Test-Bin (Join-Path $Data $f))) { return $false } }; return $true }

New-Item -ItemType Directory -Force -Path $Work, $Data | Out-Null

# --- 1. Python ---------------------------------------------------------------
Say 'Checking Python'
function Find-Python {
    foreach ($c in @(@('py','-3'), @('python'))) {
        try {
            $out = & $c[0] @($c[1..($c.Count)] + '--version') 2>&1 | Out-String
            if ($out -match 'Python 3\.(\d+)' -and [int]$Matches[1] -ge 8) { return ,$c }
        } catch {}
    }
    return $null
}
$py = Find-Python
if (-not $py) {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Warn 'Python not found - installing with winget'
        winget install -e --id Python.Python.3.12 --accept-source-agreements --accept-package-agreements
        $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
        $py = Find-Python
    }
    if (-not $py) { Die 'Python 3 not found. Install it from python.org (tick "Add to PATH"), then re-run.' }
}
Ok 'Python found'

# --- 2. stadiatool + venv ----------------------------------------------------
if (-not (Test-Path $Tool)) {
    Say 'Downloading stadiatool'
    try { Invoke-WebRequest 'https://github.com/GaryOderNichts/StadiaController/archive/refs/heads/main.zip' -OutFile $RepoZip -UseBasicParsing }
    catch { Die "Could not download stadiatool: $_" }
    Expand-Archive $RepoZip -DestinationPath $Work -Force
    if (-not (Test-Path $Tool)) { Die 'stadiatool folder missing after extract' }
}
if (-not (Test-Path $VenvPy)) {
    Say 'Creating Python environment'
    & $py[0] @($py[1..($py.Count)] + @('-m','venv',$Venv))
    if (-not (Test-Path $VenvPy)) { Die 'venv creation failed' }
}
& $VenvPy -m pip install -q --disable-pip-version-check pyusb libusb-package
if ($LASTEXITCODE -ne 0) { Die 'pip install failed' }
Ok 'stadiatool + pyusb + libusb ready'

# Wrapper so pyusb finds the libusb DLL bundled in libusb-package
$Wrapper = Join-Path $Work 'run_stadiatool.py'
@'
import sys, runpy, os
import libusb_package, usb.core, usb.backend.libusb1

be = usb.backend.libusb1.get_backend(find_library=libusb_package.find_library)
if be is None:
    sys.exit("libusb backend could not be loaded")

# Always use the bundled libusb backend
_orig_find = usb.core.find
def _find(*a, **k):
    k.setdefault("backend", be)
    return _orig_find(*a, **k)
usb.core.find = _find

# Windows/libusb has no kernel-driver detach; Linux-only calls become no-ops
def _no_driver(self, *a, **k):
    return False
def _noop(self, *a, **k):
    return None
usb.core.Device.is_kernel_driver_active = _no_driver
usb.core.Device.detach_kernel_driver    = _noop
usb.core.Device.attach_kernel_driver    = _noop

script = os.path.join(os.getcwd(), "stadiatool.py")
sys.path.insert(0, os.path.dirname(script))
sys.argv = [script] + sys.argv[1:]
runpy.run_path(script, run_name="__main__")
'@ | Set-Content -Path $Wrapper -Encoding UTF8

function Run-Tool { param([string[]]$ToolArgs)
    Push-Location $Tool
    try {
        & $VenvPy $Wrapper @ToolArgs 2>&1 | Out-Host
        $code = $LASTEXITCODE
    } finally { Pop-Location }
    return [int]$code
}
function Test-Bin([string]$p) {
    if (-not (Test-Path $p -PathType Leaf)) { return $false }
    $b = [IO.File]::ReadAllBytes($p)
    if ($b.Length -lt 256) { return $false }
    $n = [Math]::Min(256, $b.Length)
    $textish = 0
    for ($i = 0; $i -lt $n; $i++) {
        $c = $b[$i]
        if (($c -ge 32 -and $c -le 126) -or $c -eq 9 -or $c -eq 10 -or $c -eq 13) { $textish++ }
    }
    if ($textish -eq $n) { return $false }                 # pure text, e.g. an error page
    $head = [Text.Encoding]::ASCII.GetString($b, 0, [Math]::Min(64, $b.Length))
    if ($head -match '(?i)<!doctype|<html|<\?xml') { return $false }
    return $true
}
# purge bad cached files from earlier runs
foreach ($f in $Files) {
    $p = Join-Path $Data $f
    if ((Test-Path $p) -and -not (Test-Bin $p)) { Warn "Discarding invalid $f"; Remove-Item $p -Force }
}
# --- 3. Firmware files -------------------------------------------------------
if (-not (Have-AllFiles)) {
    Say "Trying Google's download URLs (likely gone)"
    foreach ($f in $Files) {
        $dest = Join-Path $Data $f
        if (-not (Test-Path $dest)) {
            try { Invoke-WebRequest "$GoogleBase/$f" -OutFile $dest -UseBasicParsing -TimeoutSec 20 } catch {}
            if (-not (Test-Bin $dest)) { Remove-Item $dest -Force -ErrorAction SilentlyContinue }
        }
    }
}
if (-not (Have-AllFiles) -and $env:STADIA_FILES) {
    Say "Copying from `$env:STADIA_FILES ($env:STADIA_FILES)"
    foreach ($f in $Files) {
        $hit = Get-ChildItem -Path $env:STADIA_FILES -Recurse -Filter $f -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { Copy-Item $hit.FullName (Join-Path $Data $f) -Force }
    }
}
if (-not (Have-AllFiles) -and (Get-Command docker -ErrorAction SilentlyContinue)) {
    Say "Extracting firmware from community mirror image $DockerImage"
    $tmp = Join-Path $Work 'dockerx'; New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    docker pull $DockerImage | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $cid = (docker create $DockerImage 2>$null | Select-Object -First 1)
        if ($cid) {
            $tar = Join-Path $tmp 'image.tar'
            docker export $cid -o $tar
            docker rm $cid | Out-Null
            if (Test-Path $tar) {
                tar -xf $tar -C $tmp '*.bin' 2>$null    # bsdtar ships with Windows 10+
                foreach ($f in $Files) {
                    $hit = Get-ChildItem -Path $tmp -Recurse -Filter $f -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($hit) { Copy-Item $hit.FullName (Join-Path $Data $f) -Force }
                }
            }
        }
    }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
if (-not (Have-AllFiles)) {
    Write-Host "`nCould not obtain:" -ForegroundColor Red
    foreach ($f in $Files) { if (-not (Test-Path (Join-Path $Data $f))) { Write-Host "  - $f" } }
    Write-Host "`nFix: install Docker Desktop (script pulls the mirror automatically), or put the files in a"
    Write-Host 'folder and re-run with:  $env:STADIA_FILES = "C:\path\to\folder"'
    exit 1
}
Ok 'All firmware files present'
# stadiatool expects a "data" dir; provide it in both likely places
foreach ($d in @((Join-Path $Repo 'data'), (Join-Path $Tool 'data'))) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    Copy-Item (Join-Path $Data '*') $d -Force
}

# --- 4. Zadig helper ---------------------------------------------------------
function Get-Zadig {
    $z = Get-ChildItem -Path $Work -Filter 'zadig*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($z) { return $z.FullName }
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Say 'Installing Zadig via winget'
        winget install -e --id akeo.ie.Zadig --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
        $p = Get-Command zadig -ErrorAction SilentlyContinue
        if ($p) { return $p.Source }
        $p = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter 'zadig*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($p) { return $p.FullName }
    }
    return $null
}
function Run-Zadig([string]$Hint) {
    Write-Host ''
    Write-Host "     In Zadig:" -ForegroundColor Yellow
    Write-Host "       1. Menu Options -> tick 'List All Devices'"
    Write-Host "       2. Pick the device: $Hint"
    Write-Host "       3. Set the target driver (right of the green arrow) to WinUSB"
    Write-Host "       4. Click 'Replace Driver' (or 'Install Driver') and wait for success"
    $z = Get-Zadig
    if ($z) {
        try { Start-Process $z -ErrorAction Stop }
        catch { Warn 'Zadig did not launch (UAC prompt declined?). Start it manually from the Start menu or https://zadig.akeo.ie/' }
    } else {
        Warn 'Opening the Zadig website - download and run zadig-*.exe'
        Start-Process 'https://zadig.akeo.ie/'
    }
}

# --- 5. Walk-through ---------------------------------------------------------
Write-Host @"

Before you start
  * Charge the controller 30+ minutes and use a USB DATA cable.
  * This replaces the controller's firmware with the generic Bluetooth build.
    Wi-Fi/Stadia mode will no longer work (it's dead anyway). Flashing has a
    small risk of bricking - don't unplug mid-flash.
"@
Pause-Step

Say 'Step 1: unlock the controller'
Write-Host @"
     a) Unplug the controller from USB.
     b) Plug it back in while holding the Options button (the "..." button).
     c) Once plugged in, hold Options + Assistant + A + Y together for a couple of seconds.
        The controller re-appears as a different USB device.
"@
Pause-Step

Say 'Waiting for the controller in flash-ready (SDP) mode...'
if (-not (Wait-Usb '1FC9' 60)) {
    if (Test-Usb '18D1') { Warn 'Controller is still in normal mode - the unlock combo did not register.' }
    Die 'Never saw SDP mode (USB vendor 1FC9). Unplug, repeat the button combo, and re-run.'
}
Ok 'Controller is in SDP mode'

Say 'Step 2: install the WinUSB driver (one-time, needed for libusb access)'
Run-Zadig "VID 1FC9 - a name like 'SE/SP Blank RT Family' or 'NXP ... Bootloader'"

Say 'Step 3: loading flashloader'
$rc = Run-Tool @('flashloader', (Join-Path $Data 'restricted_ivt_flashloader.bin'))
if ($rc -ne 0) {
    Warn 'First attempt failed, retrying once...'
    Start-Sleep -Seconds 3
    $rc = Run-Tool @('flashloader', (Join-Path $Data 'restricted_ivt_flashloader.bin'))
    if ($rc -ne 0) { Die 'Flashloader failed to load. Check the WinUSB driver was applied to the right device (VID 1FC9).' }
}
Start-Sleep -Seconds 3
Ok 'Flashloader running'

Say 'Step 4: flashing Bluetooth firmware - DO NOT UNPLUG'
$fw = Join-Path $Data 'bruce_pvt_a_prod_signed.bin'
$rc = Run-Tool @('flash_firmware', $fw)
if ($rc -ne 0) {
    Die 'Flashing failed (see error above). If it says "device not found" or access denied, re-run Zadig on the 1FC9 device; if it complains about the firmware header, the .bin file is bad.'
}
Ok 'Firmware flashed'

Say 'Step 5: resetting controller'
$rc = Run-Tool @('reset')
if ($rc -ne 0) { Warn 'Reset command errored - unplug and replug the controller manually.' }

Write-Host @"

Done!
  Pairing: unplug USB, then hold Y + Stadia for 2 seconds.
           The LED flashes orange - choose "Stadia Controller" in Settings > Bluetooth & devices.
  Factory reset: hold Assistant + Capture for 6 seconds.
  (Optional) Zadig changed the driver on the controller's *bootloader* USB IDs only;
  normal Bluetooth/USB gameplay is unaffected.
"@ -ForegroundColor Green