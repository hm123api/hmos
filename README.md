# HMOS — 自制双启动小操作系统（BIOS Legacy + UEFI x64）

基于 [Limine](https://github.com/limine-bootloader/limine) 引导器的教学型 x86_64 操作系统：
同一套内核可在 BIOS Legacy 与 UEFI 下启动，并打通了 QEMU 虚拟机内的安全引导（Secure Boot）流程。

> 现状与排查细节见 [`SECURE_BOOT_STATUS.md`](SECURE_BOOT_STATUS.md)。

## 目录结构

| 路径 | 说明 |
|---|---|
| `boot.asm` | BIOS 引导扇区（legacy MBR stage，参考保留） |
| `kernel.c` | Limine 协议 ELF64 内核（BIOS + UEFI 通用，帧图输出） |
| `uefi_main.c` | 自包含 UEFI 应用（被 Limine 链载的备用 EFI 入口） |
| `diag_main.c` | 诊断 EFI：转储安全引导相关 UEFI 变量（未接入正式构建流程） |
| `limine.h` / `font.h` | Limine 协议头、内置 8×16 字体 |
| `linker.lds` | 内核 ELF64 链接脚本 |
| `limine.conf` | Limine 引导菜单配置 |
| `build_hmos.bat` | 一键构建双启动 ISO（汇编 / 编译 / 暂存 / 签名 / xorriso 打包） |
| `sign_hmos.py` | 安全引导签名 / 哈希 / 证书导出 / 变量镜像生成工具 |
| `stage_esp_material.ps1` | 把已签名引导文件暂存到 `esp_material\`（ESP 磁盘路径） |
| `build_esp_image.sh` | Linux 侧用 losetup + mkfs.vfat 构建 ESP 镜像（旧方案，备查） |
| `qemu_test\` | QEMU 启动脚本、无头回归脚本、截图与串口日志目录 |
| `keys\` | PK/KEK/db 公钥材料（`.crt/.der/.esl`）；**私钥 `.key` 不入库** |

## 外部依赖（不随仓库提交，见 `.gitignore`）

下列第三方二进制 / 固件 / Python 包放在 `tools\` 下，仓库不收录；按版本自行下载放到对应路径。

| 依赖 | 版本 | 脚本内期望路径 |
|---|---|---|
| Limine 预编译引导器 + `limine.exe` 工具 | 12.9.6 | `tools\efi\limine\limine-binary\` |
| NASM | 3.02 | `tools\nasm.exe` |
| GNU xorriso | 1.5.2 | `tools\xorriso.exe` |
| osslsigncode | 2.16 (windows-amd64) | `tools\osslsigncode\osslsigncode-2.16-windows-amd64\osslsigncode.exe` |
| OVMF/EDK2 固件（普通 + 安全引导 code/vars） | 本机实测版本 | `tools\ovmf\edk2-ovmf-bins\` |
| 本地 Python 包（pyfatfs / fs / six / appdirs / setuptools） | 见 `tools\pylib` | 由 `PYTHONPATH=tools\pylib` 引入 |

系统级工具（不在 `tools\`，需单独安装；默认按常见安装路径查找，也可用环境变量覆盖）：

- LLVM 工具链：clang 23.1.5、lld-link、ld.lld（默认 `C:\Program Files\LLVM\bin`，可用 `CLANG`/`LLD`/`LDLLD` 环境变量覆盖）
- Python 3.14（默认 `C:\Python314\python.exe`，可用 `PYTHON` 环境变量覆盖）
- OpenSSL（默认随 Git for Windows：`C:\Program Files\Git\usr\bin\openssl.exe`，可用 `OPENSSL` 环境变量覆盖）
- QEMU 11.1.0（默认 `C:\Program Files\qemu\qemu-system-x86_64.exe`，可用 `QEMU` 环境变量覆盖）

## 构建双启动 ISO

在项目根目录执行：

```bat
build_hmos.bat
```

流程（脚本内 8 步）：汇编 BIOS 扇区 → 编译 UEFI 应用 → 编译 ELF64 内核 → 暂存 Limine 文件 →
`sign_hmos.py sign-stage` 做内核哈希 / 配置哈希 enroll / Authenticode 签名 → xorriso 打包 hybrid ISO →
`limine.exe bios-install` 写入 BIOS stage2。产物 `hmos.iso`（已被 `.gitignore` 排除，可重建）。

## QEMU 测试

`qemu_test\` 下三个双击入口（均调用 `run_qemu.ps1`）：

| 入口 | 模式 | 挂载 |
|---|---|---|
| `启动-BIOS.bat` | SeaBIOS legacy | `hmos.iso` 光盘 |
| `启动-UEFI.bat` | 普通 OVMF x64 | `hmos.iso` 光盘 |
| `启动-SecureBoot.bat` | 安全引导 OVMF | ESP 硬盘镜像 `qemu_test\fw\esp.img` |

无头回归：

```powershell
# 非安全引导双模式（定时退出，截图落 shots\）
.\qemu_test\run_test.ps1 -Mode uefi -Seconds 12
.\qemu_test\run_test.ps1 -Mode bios  -Seconds 12

# 安全引导硬盘镜像
.\qemu_test\run_sb_disk_test.ps1 -Seconds 12

# 键盘交互冒烟测试：BIOS 启动后经 monitor 发送按键，核对回显与回车提交
.\qemu_test\run_kbd_test.ps1

# 光标/方向键测试：输入后左右移动光标，核对块光标落在正确格内、不压字形
.\qemu_test\run_cursor_test.ps1
```

### 内核 Shell（ASCII 输入）

`kernel.c` 在帧缓冲上实现了一个最简命令行：PS/2 端口 0x60 轮询扫描码，行缓冲 + 光标定位，
支持可打印字符插入、退格、左右方向键、Del、回车提交；方向键 / Del 走 E0 扩展扫描码前缀。
回车后回显命令行并输出占位回复，命令派发钩子留在 `run_command()`。光标为纯色块 + 反色字形，
每次重绘整格先擦干净，不做跨帧叠加，因此不会在字符格上留残影；闪烁节拍基于 Limine TSC
频率请求，按真实 500ms 翻转。当前仅 ASCII，中文渲染留待后续。

### 安全引导要点

- 安全引导**走 ESP 磁盘镜像**，不走光盘：光盘 El Torito 第一阶段 `limine-uefi-cd.bin` 未签名，固件在加载签名 EFI 之前就拒绝整盘。
- 配置哈希口径：**整文件 BLAKE2B**（不是 size-2）；内核哈希同样整文件 BLAKE2B，追加到 `limine.conf` 路径 `#` 后。
- UEFI 菜单鼠标：edk2/OVMF 不给 QEMU 的 USB tablet 暴露指针协议；QEMU 指针设备用 PCI `virtio-tablet-pci`（见 `run_qemu.ps1`）。

## 密钥与安全提醒

- `keys\` 下 `.key` 为签名私钥，已在 `.gitignore` 中排除，**切勿提交到公开仓库**。
- 入库的 `.crt/.der/.esl` 是公钥材料，可用于在固件里登记 PK/KEK/db。
- `keys\auth\` 目录用于存放完整认证变量包（`.auth`，含私钥签名），已在 `.gitignore` 中排除，不入库。
- `keys\alt\` 是错配 db 对照证书（诱饵），用于安全引导拒绝路径的对照测试。
- **真机登记（暂停，未打通）**：出厂 User Mode 下追加自建 db 必须由现有 KEK 签名，自建根链签不动出厂 ASUS/微软根；可行方向是先进固件 `Reset To Setup Mode`，再按 db→KEK→PK 登记 `.esl`，详见 `SECURE_BOOT_STATUS.md` 8.0.9。当前未在真机执行登记。
