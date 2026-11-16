@echo off
chcp 437 >nul 2>nul
setlocal EnableExtensions

echo ======================================
echo HMOS Dual-Boot ISO Builder (BIOS + UEFI)
echo Bootloader: Limine (prebuilt, vendored in tools\efi)
echo ======================================

set NASM=tools\nasm.exe
if not defined CLANG set "CLANG=C:\Program Files\LLVM\bin\clang.exe"
if not defined LLD set "LLD=C:\Program Files\LLVM\bin\lld-link.exe"
if not defined LDLLD set "LDLLD=C:\Program Files\LLVM\bin\ld.lld.exe"
set XORRISO=tools\xorriso.exe
if not defined PY set "PY=C:\Python314\python.exe"
set LIMINE=tools\efi\limine\limine-binary
set LIMINE_TOOL=tools\efi\limine\limine-binary\limine-tool-windows-x86\limine.exe
set BUILD=build
set TMP_ROOT=iso_root

rem Ensure project-local Python packages are visible to the system Python.
set PYTHONNOUSERSITE=
set PYTHONPATH=tools\pylib

echo [1/8] Clean old files...
if exist %TMP_ROOT% rmdir /s /q %TMP_ROOT%
if exist %BUILD% rmdir /s /q %BUILD%
if exist hmos.iso del /q hmos.iso
mkdir %BUILD%
mkdir %TMP_ROOT%\EFI\BOOT
mkdir %TMP_ROOT%\boot\limine

echo [2/8] Assemble BIOS boot.bin (legacy MBR stage, kept for reference)
%NASM% -f bin boot.asm -o %TMP_ROOT%\boot.bin
if errorlevel 1 (
    echo ERROR: BIOS assemble failed
    if /i "%~1"=="nopause" exit /b 1
    pause
    exit /b 1
)

echo [3/8] Compile UEFI BOOTX64.EFI (HMOS app, chainloaded by Limine)
"%CLANG%" --target=x86_64-unknown-windows -ffreestanding -fshort-wchar -mno-red-zone -fno-stack-protector -fno-exceptions -fno-unwind-tables -fno-asynchronous-unwind-tables -c uefi_main.c -o %BUILD%\uefi.obj
if errorlevel 1 (
    echo ERROR: UEFI compile failed
    if /i "%~1"=="nopause" exit /b 1
    pause
    exit /b 1
)
"%LLD%" /NOLOGO /NODEFAULTLIB /SUBSYSTEM:EFI_APPLICATION /ENTRY:efi_main /MACHINE:X64 /DYNAMICBASE /HIGHENTROPYVA:NO /BASE:0 /FILEALIGN:0x200 /NXCOMPAT:NO /TSAWARE:NO /LARGEADDRESSAWARE:NO /HEAP:0 /STACK:0 /OPT:REF /MERGE:.pdata=.rdata /OUT:%BUILD%\BOOTX64.EFI %BUILD%\uefi.obj
if errorlevel 1 (
    echo ERROR: UEFI link failed
    if /i "%~1"=="nopause" exit /b 1
    pause
    exit /b 1
)

echo [4/8] Compile HMOS Limine-protocol kernel (ELF64, BIOS + UEFI)
"%CLANG%" -target x86_64-unknown-none-elf -ffreestanding -mno-red-zone -fno-stack-protector -fno-exceptions -fno-unwind-tables -fno-asynchronous-unwind-tables -c kernel.c -o %BUILD%\kernel.obj
if errorlevel 1 (
    echo ERROR: kernel compile failed
    if /i "%~1"=="nopause" exit /b 1
    pause
    exit /b 1
)
"%LDLLD%" -m elf_x86_64 -static -z max-page-size=0x1000 --gc-sections -T linker.lds -o %BUILD%\kernel.bin %BUILD%\kernel.obj
if errorlevel 1 (
    echo ERROR: kernel link failed
    if /i "%~1"=="nopause" exit /b 1
    pause
    exit /b 1
)

echo [5/8] Stage Limine bootloader files into ISO root
rem Limine EFI application (UEFI fallback path: /EFI/BOOT/BOOTX64.EFI)
copy /y %LIMINE%\BOOTX64.EFI %TMP_ROOT%\EFI\BOOT\BOOTX64.EFI >nul
rem HMOS app chainloaded by the Limine menu entry, kept at a side path
copy /y %BUILD%\BOOTX64.EFI %TMP_ROOT%\EFI\BOOT\HMOS.EFI >nul
rem HMOS native Limine-protocol kernel
copy /y %BUILD%\kernel.bin %TMP_ROOT%\boot\hmoskernel >nul
rem Limine BIOS/UEFI CD boot images and BIOS stage2 file
copy /y %LIMINE%\limine-bios-cd.bin  %TMP_ROOT%\boot\limine\limine-bios-cd.bin >nul
copy /y %LIMINE%\limine-uefi-cd.bin  %TMP_ROOT%\boot\limine\limine-uefi-cd.bin >nul
copy /y %LIMINE%\limine-bios.sys     %TMP_ROOT%\boot\limine\limine-bios.sys >nul
rem Limine config (placed at /limine.conf for the documented scan path)
copy /y limine.conf %TMP_ROOT%\limine.conf >nul

echo [6/8] Secure Boot: enrol config hash, append kernel hash, sign EFI images
"%PY%" sign_hmos.py sign-stage %TMP_ROOT%
if errorlevel 1 (
    echo ERROR: Secure Boot signing stage failed
    if /i "%~1"=="nopause" exit /b 1
    pause
    exit /b 1
)

echo [7/8] Build hybrid ISO (BIOS + UEFI)
%XORRISO% -as mkisofs -R -r -J -hfsplus ^
-apm-block-size 2048 ^
-b boot/limine/limine-bios-cd.bin ^
-no-emul-boot -boot-load-size 4 -boot-info-table ^
--efi-boot boot/limine/limine-uefi-cd.bin ^
-efi-boot-part --efi-boot-image --protective-msdos-label ^
%TMP_ROOT% -o hmos.iso
if errorlevel 1 (
    echo ERROR: ISO build failed
    if /i "%~1"=="nopause" exit /b 1
    pause
    exit /b 1
)

echo [8/8] Install Limine BIOS stage2 onto the ISO image
%LIMINE_TOOL% bios-install hmos.iso
if errorlevel 1 (
    echo WARNING: limine bios-install reported an error
)

echo.
echo SUCCESS! Output: hmos.iso
echo.
if /i not "%~1"=="nopause" pause
