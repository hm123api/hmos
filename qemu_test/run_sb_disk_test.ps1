param(
    [int]$Seconds = 15,
    [string]$Disk = "",
    [string]$CodeFw = "",
    [string]$VarsFw = "",
    [switch]$Window
)

# HMOS Secure Boot QEMU test over an ESP DISK image (NOT the CD ISO).
# This is the SB-correct boot path: firmware reads /EFI/BOOT/BOOTX64.EFI from a
# FAT32 ESP partition directly, bypassing the unsigned limine-uefi-cd.bin layer.
# 安全引导请用本脚本；光盘 ISO 的安全引导路径走不通（见 run_sb_test.ps1 顶部说明）。
#
# Requires esp.img built on a Linux/real-machine with FAT formatting support
# (see build_esp_image.sh). Screenshots -> shots\sb-disk-<n>.ppm.

$ErrorActionPreference = "Stop"
# Project root = parent of this script's qemu_test\ folder (portable clone).
$root   = Split-Path -Parent $PSScriptRoot
$qexe   = if ($env:QEMU) { $env:QEMU } else { "C:\Program Files\qemu\qemu-system-x86_64.exe" }
$tdir   = "$root\qemu_test"
$shots  = "$tdir\shots"
$fw     = "$tdir\fw"
New-Item -ItemType Directory -Force -Path $shots | Out-Null

if (-not $Disk)   { $Disk   = "$fw\esp.img" }
if (-not $CodeFw) { $CodeFw = "$root\tools\ovmf\edk2-ovmf-bins\ovmf-code-x86_64-secboot.fd" }
if (-not $VarsFw) { $VarsFw = "$fw\vars-official-keys.fd" }

$serial = "$tdir\serial-sb-disk.log"
$debug  = "$tdir\debugcon-sb-disk.log"

if (-not (Test-Path -LiteralPath $Disk))   { Write-Host "ERROR: disk image missing: $Disk"; exit 1 }
if (-not (Test-Path -LiteralPath $CodeFw)) { Write-Host "ERROR: secure code fw missing: $CodeFw"; exit 1 }
if (-not (Test-Path -LiteralPath $VarsFw))  { Write-Host "ERROR: enrolled vars missing: $VarsFw"; exit 1 }

# Fresh writable copy of the enrolled vars so the run does not mutate the template.
$varsRun = "$fw\vars-run-secure-disk.fd"
Copy-Item -LiteralPath $VarsFw -Destination $varsRun -Force

$monPort = 55557

$display = if ($Window) { "gtk" } else { "none" }

$qargs = @(
    "-nodefaults", "-no-user-config",
    "-machine", "pc-q35-9.2,smm=on",
    "-m", "512",
    # ESP image as a SATA/IDE hard disk (first boot device) instead of CD-ROM.
    "-drive", "file=$Disk,format=raw,media=disk,if=none,id=espdisk",
    "-device", "ide-hd,drive=espdisk,bus=ide.0",
    "-boot", "c",
    "-serial", "file:$serial",
    "-chardev", "file,id=debugcon,path=$debug",
    "-device", "isa-debugcon,iobase=0xe9,chardev=debugcon",
    "-monitor", "tcp:127.0.0.1:$monPort,server=on,wait=off",
    "-vga", "std",
    "-display", $display,
    # UEFI pointer: edk2 exposes no pointer protocol for QEMU USB tablet;
    # use a PCI virtio-tablet (absolute pointer) that the firmware binds.
    "-device", "virtio-tablet-pci",
    "-drive", "if=pflash,unit=0,format=raw,readonly=on,file=$CodeFw",
    "-drive", "if=pflash,unit=1,format=raw,file=$varsRun",
    "-global", "driver=cfi.pflash01,property=secure,value=on"
)

Write-Host "[sb-disk] sec=$Seconds"
Write-Host "[sb-disk] disk: $Disk"
Write-Host "[sb-disk] code: $CodeFw"
Write-Host "[sb-disk] vars: $varsRun"

$proc = Start-Process -FilePath $qexe -ArgumentList $qargs -NoNewWindow -PassThru `
    -RedirectStandardOutput "$tdir\qemu-sb-disk-stdout.log" `
    -RedirectStandardError  "$tdir\qemu-sb-disk-stderr.log"

function Send-Monitor([string]$cmd) {
    try {
        $c = New-Object System.Net.Sockets.TcpClient("127.0.0.1", $monPort)
        $w = New-Object System.IO.StreamWriter($c.GetStream())
        $w.NewLine = "`n"
        $w.WriteLine($cmd); $w.Flush()
        Start-Sleep -Milliseconds 250
        $c.Close()
    } catch { Write-Host "[monitor] $($_.Exception.Message)" }
}

$deadline = (Get-Date).AddSeconds($Seconds)
$n = 0
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    if ($proc.HasExited) { Write-Host "[sb-disk] qemu exited early code=$($proc.ExitCode)"; break }
    $n++
    $ppm = "$shots\sb-disk-$n.ppm"
    Send-Monitor "screendump $ppm"
    Write-Host "[shot] $ppm"
}

Send-Monitor "quit"
Start-Sleep -Milliseconds 500
if (-not $proc.HasExited) { $proc.Kill() }
Write-Host "[sb-disk] done. serial: $serial"
