@echo off
rem Launch HMOS in QEMU, Secure Boot OVMF (enrolled keys), ESP disk image.
rem 安全引导走 esp.img 硬盘镜像；光盘 ISO 在安全引导下会被拒绝（见 SECURE_BOOT_STATUS.md）。
setlocal
set PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_qemu.ps1" -Mode secure
endlocal
