param(
    [int]$Seconds = 14
)

# Smoke test: type "hello", move the cursor left twice, screendump to verify
# the block cursor sits cleanly over the middle cell without corrupting glyphs.

$ErrorActionPreference = "Stop"
$root   = Split-Path -Parent $PSScriptRoot
$qexe   = if ($env:QEMU) { $env:QEMU } else { "C:\Program Files\qemu\qemu-system-x86_64.exe" }
$iso    = "$root\hmos.iso"
$tdir   = "$root\qemu_test"
$shots  = "$tdir\shots"
New-Item -ItemType Directory -Force -Path $shots | Out-Null

$monPort = 55562
$serial  = "$tdir\serial-cursor.log"

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
    -RedirectStandardOutput "$tdir\cursor-stdout.log" `
    -RedirectStandardError  "$tdir\cursor-stderr.log"

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

Start-Sleep -Seconds 6

foreach ($ch in @("h","e","l","l","o")) { Send-Monitor "sendkey $ch" }
Start-Sleep -Milliseconds 500
Send-Monitor "screendump $shots\cursor-type.ppm"

# Move cursor left twice: hello -> h e [l] l o
Send-Monitor "sendkey left"
Start-Sleep -Milliseconds 250
Send-Monitor "sendkey left"
Start-Sleep -Milliseconds 500
Send-Monitor "screendump $shots\cursor-mid.ppm"

# Move right back to end.
Send-Monitor "sendkey right"
Send-Monitor "sendkey right"
Start-Sleep -Milliseconds 500
Send-Monitor "screendump $shots\cursor-end.ppm"

Start-Sleep -Seconds 1
Send-Monitor "quit"
Start-Sleep -Milliseconds 500
if (-not $proc.HasExited) { $proc.Kill() }
Write-Host "[cursor] done."
