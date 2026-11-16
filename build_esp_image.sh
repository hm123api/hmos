#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# build_esp_image.sh — 在具备格式化工具的 Linux 环境构造 HMOS FAT32 ESP 磁盘镜像
#
# 背景（SECURE_BOOT_STATUS.md）：Secure Boot 下光盘 El Torito 第一阶段
# limine-uefi-cd.bin 未签名，固件在加载签名过的 BOOTX64.EFI 前就拒绝整盘。
# SB 必须走 GPT/FAT32 ESP 磁盘：固件直接读 ESP 上的 /EFI/BOOT/BOOTX64.EFI。
#
# 本脚本不在 Windows 本机执行；需在一台有 root/sudo 且具备 losetup +
# mkfs.vfat + sgdisk 的 Linux 上运行（或真机直接装到 ESP 分区）。
#
# 用法：
#   sudo SIZE_MB=64 bash build_esp_image.sh
#
# 产物：esp.img —— 单 GPT FAT32 ESP 分区，内含已签名引导文件与内核。
# ----------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
MAT="$ROOT/esp_material"
OUT="$ROOT/esp.img"
SIZE_MB="${SIZE_MB:-64}"
LOOP="$(losetup -f)"

need() { command -v "$1" >/dev/null || { echo "缺少依赖: $1"; exit 1; }; }
need losetup; need mkfs.vfat; need sgdisk

[ -d "$MAT/EFI/BOOT" ] || { echo "缺少 $MAT/EFI/BOOT；先在 Windows 侧生成 esp_material"; exit 1; }

echo "[1/6] 分配 ${SIZE_MB} MiB 空镜像 $OUT"
rm -f "$OUT"
dd if=/dev/zero of="$OUT" bs=1M count="$SIZE_MB" status=none

echo "[2/6] 绑定循环设备并写 GPT / ESP 分区"
losetup -P "$LOOP" "$OUT"
# 类型 GUID C12A7328-F81F-11D2-BA4B-00A0C93EC93B = ESP
sgdisk -n 1:2048:0 -t 1:ef00 -c 1:HMOS_ESP "$OUT"
PART="${LOOP}p1"
[ -b "$PART" ] || PART="${LOOP}1"
sleep 1

echo "[3/6] 格式化分区为 FAT32"
mkfs.vfat -F 32 -n "HMOS_ESP" "$PART"

echo "[4/6] 挂载并写入 ESP 文件"
MNT="$(mktemp -d)"
mount "$PART" "$MNT"
mkdir -p "$MNT/EFI/BOOT" "$MNT/boot/limine"
cp -v "$MAT/EFI/BOOT/BOOTX64.EFI" "$MNT/EFI/BOOT/"
cp -v "$MAT/EFI/BOOT/HMOS.EFI"    "$MNT/EFI/BOOT/"
cp -v "$MAT/boot/hmoskernel"       "$MNT/boot/"
cp -v "$MAT/limine.conf"           "$MNT/"
cp -v "$MAT/boot/limine/limine-bios.sys" "$MNT/boot/limine/"
sync
umount "$MNT"
rmdir "$MNT"

echo "[5/6] 安装 Limine BIOS 链载（可选；UEFI SB 不依赖此项）"
# limine 工具在 Linux 上可编译或从 release 取对应二进制；缺失则跳过。
if command -v limine >/dev/null; then
  limine bios-install "$OUT" 1 || echo "  (bios-install 跳过)"
fi

losetup -d "$LOOP"
echo "[6/6] 完成: $OUT"
echo "在 QEMU 中以磁盘（非光盘）挂载，并使用已登记密钥的 secure vars 启动。"
