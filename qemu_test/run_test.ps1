param(
    [ValidateSet("bios","uefi")]
    [string]$Mode = "uefi",
    [int]$Seconds = 12
)

# HMOS QEMU headless test runner.
# bios  -> SeaBIOS (legacy) boots hybrid ISO
# uefi  -> EDK2/OVMF x86_64 boots hybrid ISO
# Screenshots -> qemu_test\shots\<mode>-<n>.ppm ; serial -> qemu_test\serial-<mode>.log

$ErrorActionPreference = "Stop"
# Project root = parent of this script's qemu_test\ folder (portable clone).
$root   = Split-Path -Parent $PSScriptRoot
$qexe   = if ($env:QEMU) { $env:QEMU } else { "C:\Program Files\qemu\qemu-system-x86_64.exe" }
$iso    = "$root\hmos.iso"
$tdir   = "$root\qemu_test"
$shots  = "$tdir\shots"
$fw     = "$tdir\fw"
$ovmf   = "$root\tools\ovmf\edk2-ovmf-bins"
New-Item -ItemType Directory -Force -Path $shots | Out-Null

$codeFw  = "$ovmf\ovmf-code-x86_64.fd"
$varsTpl = "$ovmf\ovmf-vars-x86_64.fd"
$varsFw  = "$fw\vars-run-uefi.fd"
$serial  = "$tdir\serial-$Mode.log"

if ($Mode -eq "uefi") { Copy-Item $varsTpl $varsFw -Force }

$monPort = 55555

$qargs = @(
    "-machine", "pc-q35-9.2",
    "-m", "512",
    "-drive", "file=$iso,media=cdrom,index=2",
    "-boot", "d",
    "-serial", "file:`"$serial`"",
    "-monitor", "tcp:127.0.0.1:$monPort,server=on,wait=off",
    "-vga", "std",
    "-display", "none"
)
if ($Mode -eq "uefi") {
    $qargs += @(
        "-drive", "if=pflash,format=raw,readonly=on,file=$codeFw",
        "-drive", "if=pflash,format=raw,file=$varsFw"
    )
}

Write-Host "[test] mode=$Mode sec=$Seconds"
Write-Host ("[test] qemu: " + $qexe)

$proc = Start-Process -FilePath $qexe -ArgumentList $qargs -NoNewWindow -PassThru `
    -RedirectStandardOutput "$tdir\qemu-stdout.log" `
    -RedirectStandardError  "$tdir\qemu-stderr.log"

function Send-Monitor([string]$cmd) {
    try {
        $c = New-Object System.Net.Sockets.TcpClient("127.0.0.1", $monPort)
        $w = New-Object System.IO.StreamWriter($c.GetStream())
        $w.NewLine = "`n"
        $w.WriteLine($cmd); $w.Flush()
        Start-Sleep -Milliseconds 250
        $c.Close()
    } catch { Write-Host ("[monitor] " + $_.Exception.Message) }
}

$deadline = (Get-Date).AddSeconds($Seconds)
$n = 0
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    if ($proc.HasExited) { Write-Host "[test] qemu exited early code=$($proc.ExitCode)"; break }
    $n++
    $ppm = "$shots\$Mode-$n.ppm"
    Send-Monitor "screendump $ppm"
    Write-Host "[shot] $ppm"
}

Send-Monitor "quit"
Start-Sleep -Milliseconds 500
if (-not $proc.HasExited) { $proc.Kill() }
Write-Host "[test] done. serial: $serial"
