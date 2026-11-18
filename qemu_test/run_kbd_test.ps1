param(
    [int]$Seconds = 14
)

# Temporary interactive smoke test: boot BIOS ISO, send keys over the QEMU
# monitor, screendump to verify the shell echoes typed input and the Enter
# submission placeholder works. Not part of the shipped test suite.

$ErrorActionPreference = "Stop"
$root   = Split-Path -Parent $PSScriptRoot
$qexe   = if ($env:QEMU) { $env:QEMU } else { "C:\Program Files\qemu\qemu-system-x86_64.exe" }
$iso    = "$root\hmos.iso"
$tdir   = "$root\qemu_test"
$shots  = "$tdir\shots"
New-Item -ItemType Directory -Force -Path $shots | Out-Null

$monPort = 55561
$serial  = "$tdir\serial-kbd.log"

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

$proc = Start-Process -FilePath $qexe -ArgumentList $qargs -NoNewWindow -PassThru `
    -RedirectStandardOutput "$tdir\kbd-stdout.log" `
    -RedirectStandardError  "$tdir\kbd-stderr.log"

function Send-Monitor([string]$cmd) {
    try {
        $c = New-Object System.Net.Sockets.TcpClient("127.0.0.1", $monPort)
        $w = New-Object System.IO.StreamWriter($c.GetStream())
        $w.NewLine = "`n"
        $w.WriteLine($cmd); $w.Flush()
        Start-Sleep -Milliseconds 200
        $c.Close()
    } catch { Write-Host "[monitor] $($_.Exception.Message)" }
}

# Wait for Limine countdown + kernel handoff before sending keys.
Start-Sleep -Seconds 6

# Type "hello" then Enter.
foreach ($ch in @("h","e","l","l","o")) { Send-Monitor "sendkey $ch" }
Start-Sleep -Milliseconds 600
Send-Monitor "screendump $shots\kbd-after-type.ppm"
Start-Sleep -Milliseconds 300

Send-Monitor "sendkey ret"
Start-Sleep -Milliseconds 600
Send-Monitor "screendump $shots\kbd-after-enter.ppm"

Start-Sleep -Seconds 2
Send-Monitor "quit"
Start-Sleep -Milliseconds 500
if (-not $proc.HasExited) { $proc.Kill() }
Write-Host "[kbd] done."
