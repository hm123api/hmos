param(
    [switch]$SkipSign
)

# Stage the signed HMOS boot files into esp_material\ — the tree that gets copied
# onto the FAT32 ESP partition (Secure Boot disk path; see SECURE_BOOT_STATUS.md).
#
# Flow:
#   1. Assemble/compile BIOS boot.bin, UEFI HMOS.EFI, ELF kernel (reuse build_hmos.bat
#      stages if needed) — this script expects iso_root already staged by build_hmos.bat.
#   2. sign-stage: kernel hash -> conf patch -> config hash enroll -> Authenticode sign.
#   3. Copy the signed EFI, kernel, conf, limine-bios.sys into esp_material\.
#
# Run after build_hmos.bat, or call with -SkipSign only to re-copy an already signed tree.

$ErrorActionPreference = "Stop"
# Project root = this script's folder (portable clone).
$root  = $PSScriptRoot
$py    = if ($env:PYTHON) { $env:PYTHON } else { "C:\Python314\python.exe" }
$iso   = "$root\iso_root"
$mat   = "$root\esp_material"

foreach ($d in @("$mat\EFI\BOOT", "$mat\boot\limine")) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}

if (-not $SkipSign) {
    Write-Host "[stage] sign-stage $iso"
    & $py "$root\sign_hmos.py" sign-stage $iso
    if ($LASTEXITCODE -ne 0) { throw "sign-stage failed" }
} else {
    Write-Host "[stage] -SkipSign: re-copying already signed tree"
}

Copy-Item "$iso\EFI\BOOT\BOOTX64.EFI" "$mat\EFI\BOOT\BOOTX64.EFI" -Force
Copy-Item "$iso\EFI\BOOT\HMOS.EFI"    "$mat\EFI\BOOT\HMOS.EFI"    -Force
Copy-Item "$iso\boot\hmoskernel"      "$mat\boot\hmoskernel"       -Force
Copy-Item "$iso\limine.conf"          "$mat\limine.conf"          -Force
Copy-Item "$root\tools\efi\limine\limine-binary\limine-bios.sys" "$mat\boot\limine\limine-bios.sys" -Force

Write-Host "[stage] esp_material ready:"
Get-ChildItem $mat -Recurse -File | ForEach-Object { Write-Host ("  " + $_.FullName.Substring($mat.Length+1) + "  (" + $_.Length + ")") }
