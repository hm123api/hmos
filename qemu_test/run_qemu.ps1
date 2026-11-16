param(
    [ValidateSet("uefi", "bios", "secure")]
    [string]$Mode = "uefi",
    [string]$Iso  = "",
    [string]$Disk = "",
    [int]$Memory  = 512,
    [int]$Seconds = 0,
    [switch]$NoWindow
)

# HMOS QEMU launcher (interactive, windowed by default).
#   uefi   -> plain EDK2/OVMF x86_64 (non Secure Boot), boots hmos.iso (CD)
#   bios   -> SeaBIOS legacy, boots hmos.iso (CD)
#   secure -> OVMF Secure Boot code + enrolled vars, boots the ESP DISK image
#             (fw\esp.img). The CD ISO path under Secure Boot is rejected
#             because limine-uefi-cd.bin is unsigned; see SECURE_BOOT_STATUS.md.
#
# Examples:
#   .\run_qemu.ps1                 # UEFI, hmos.iso, window
#   .\run_qemu.ps1 -Mode bios
#   .\run_qemu.ps1 -Mode secure
#   .\run_qemu.ps1 -NoWindow       # headless (for automated tests)

$ErrorActionPreference = "Stop"
$root   = "C:\Users\hm\Desktop\hmos"
$qexe   = "C:\Program Files\qemu\qemu-system-x86_64.exe"
$tdir   = "$root\qemu_test"
$fwdir  = "$tdir\fw"
$ovmf   = "$root\tools\ovmf\edk2-ovmf-bins"
New-Item -ItemType Directory -Force -Path $fwdir, "$tdir\shots" | Out-Null

if (-not $Iso) { $Iso = "$root\hmos.iso" }
if (-not $Disk) { $Disk = "$fwdir\esp.img" }
if (-not (Test-Path -LiteralPath $qexe)) { throw "QEMU not found: $qexe" }

# Per-mode firmware. Secure mode keeps a writable copy of the enrolled vars so
# the run does not mutate the template.
$codeFw = $null
$varsFw = $null
switch ($Mode) {
    "uefi" {
        $codeFw = "$ovmf\ovmf-code-x86_64.fd"
        $varsTpl = "$ovmf\ovmf-vars-x86_64.fd"
        $varsFw  = "$fwdir\vars-run-uefi.fd"
        Copy-Item -LiteralPath $varsTpl -Destination $varsFw -Force
    }
    "secure" {
        $codeFw = "$ovmf\ovmf-code-x86_64-secboot.fd"
        $varsTpl = "$fwdir\vars-official-keys.fd"
        if (-not (Test-Path -LiteralPath $varsTpl)) {
            $varsTpl = "$ovmf\ovmf-vars-x86_64-secboot.fd"
        }
        $varsFw = "$fwdir\vars-run-secure.fd"
        Copy-Item -LiteralPath $varsTpl -Destination $varsFw -Force
        if (-not (Test-Path -LiteralPath $Disk)) { throw "ESP disk image not found: $Disk (run the secure-boot image build; the CD ISO path is rejected under Secure Boot)." }
    }
    "bios" {
        # SeaBIOS: no pflash firmware needed.
    }
}

$serial = "$tdir\serial-$Mode.log"
$machine = "pc-q35-9.2"
if ($Mode -eq "secure") { $machine = "pc-q35-9.2,smm=on" }

$qargs = @(
    "-machine", $machine,
    "-m", "$Memory",
    "-serial", "file:$serial",
    "-vga", "std",
    "-net", "none",
    # UEFI pointer: per Limine's own test notes, edk2/OVMF exposes NO pointer
    # protocol for QEMU's USB tablet. On UEFI use a PCI virtio-tablet (absolute
    # pointer); the firmware binds it and exposes the Absolute Pointer Protocol
    # to the bootloader. Keyboard stays on the default PS/2 path.
    "-device", "virtio-tablet-pci"
)

if ($Mode -eq "secure") {
    # Secure Boot boots the ESP disk image (FAT32 partition), not the CD ISO.
    $qargs += @(
        "-drive", "file=$Disk,format=raw,media=disk,if=none,id=espdisk",
        "-device", "ide-hd,drive=espdisk,bus=ide.0",
        "-boot", "c"
    )
} else {
    if (-not (Test-Path -LiteralPath $Iso)) { throw "ISO not found: $Iso" }
    $qargs += @(
        "-drive", "file=$Iso,media=cdrom,index=2",
        "-boot", "d"
    )
}

if ($Mode -ne "bios") {
    $qargs += @(
        "-drive", "if=pflash,unit=0,format=raw,readonly=on,file=$codeFw",
        "-drive", "if=pflash,unit=1,format=raw,file=$varsFw"
    )
}
if ($Mode -eq "secure") {
    $qargs += @(
        "-global", "driver=cfi.pflash01,property=secure,value=on"
    )
}
if ($NoWindow) {
    $qargs += "-display", "none"
} else {
    $qargs += "-display", "gtk"
}

Write-Host "[qemu] mode=$Mode"
if ($Mode -eq "secure") { Write-Host "[qemu] disk=$Disk" } else { Write-Host "[qemu] iso =$Iso" }
if ($codeFw) { Write-Host "[qemu] code=$codeFw" }
if ($varsFw) { Write-Host "[qemu] vars=$varsFw" }
Write-Host "[qemu] serial=$serial"

if ($Seconds -gt 0) {
    # Headless timed run: launch, wait, then quit (mirrors the disk test runner).
    $monPort = 55558
    $qargs += @("-monitor", "tcp:127.0.0.1:$monPort,server=on,wait=off")
    $proc = Start-Process -FilePath $qexe -ArgumentList $qargs -NoNewWindow -PassThru
    Start-Sleep -Seconds $Seconds
    try {
        $c = New-Object System.Net.Sockets.TcpClient("127.0.0.1", $monPort)
        $w = New-Object System.IO.StreamWriter($c.GetStream())
        $w.NewLine = "`n"; $w.WriteLine("quit"); $w.Flush(); $c.Close()
    } catch { Write-Host "[monitor] $($_.Exception.Message)" }
    Start-Sleep -Milliseconds 500
    if (-not $proc.HasExited) { $proc.Kill() }
    Write-Host "[qemu] timed run done. serial: $serial"
    exit 0
}

& $qexe @qargs
$rc = $LASTEXITCODE
Write-Host "[qemu] exited rc=$rc"
exit $rc
