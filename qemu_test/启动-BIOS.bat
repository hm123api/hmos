@echo off
rem Launch HMOS in QEMU, legacy BIOS (SeaBIOS) windowed.
setlocal
set PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_qemu.ps1" -Mode bios
endlocal
