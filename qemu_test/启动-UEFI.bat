@echo off
rem Launch HMOS in QEMU, plain UEFI (OVMF) windowed.
setlocal
set PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_qemu.ps1" -Mode uefi
endlocal
