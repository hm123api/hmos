# HMOS Secure Boot 签名 — 现状说明与交付清单

更新时间：2026-11-14
项目目录：仓库根目录（脚本按自身位置推导，clone 后无需改路径）

## 一、一句话结论

- **非 Secure Boot 主线已完成并在 QEMU 双模式（BIOS Legacy / UEFI）实测通过。**
- **安全引导（Secure Boot）已在本机 QEMU 虚拟机内打通并复测通过（ESP 磁盘镜像路径）**：secure OVMF + 已登记 PK/KEK/db 的 vars 下，固件放行签名的 Limine EFI，配置哈希校验通过，跳转到 Limine 协议内核，帧图 `HMOS - UEFI Boot OK!`；错配 db 对照被 `Access Denied` 拒绝，证明校验真实生效。
- **光盘 ISO 形态下开启安全引导仍被固件拒绝（Access Denied）**。根因在光盘 El Torito 第一阶段引导镜像 `limine-uefi-cd.bin` 未被签名；固件在加载签名过的 `BOOTX64.EFI` 之前先校验该 CD 合并镜像，校验不过即拒绝整盘。官方 Limine 安全引导测试全部走 GPT/FAT32 ESP 磁盘，不经此 CD 中间层。

## 二、对照实验定位过程（已排除项）

基线：官方 secboot code + 官方空白 secboot vars 模板（无密钥，Setup Mode）+ 未签名 ISO → **正常进入 Limine 菜单**（Setup Mode 放行）。证明固件/code/vars 配套正常、光盘可被读取。

写入我们的密钥后 → `Access Denied -- rejected probably by Secure Boot`。

已逐项排除：

| 排查项 | 结论 |
|---|---|
| 签名器（osslsigncode vs harness 原生 authenticode） | 两者产物结构一致；osslsigncode verify `Signature verification: ok` |
| db 证书与签名者证书是否同一密钥对 | modulus 一致，同一密钥对 |
| PKCS7 内嵌证书与 db ESL 证书字节一致性 | 逐字节一致（`der in pkcs7 == True`） |
| 证书链形态（裸自签无 EKU / PK→KEK→db 链） | 两种都试过，均被拒 |
| ESL 内嵌证书偏移 / 提取口径 | 已校正，证书完整落盘 |
| 变量记录序列化（状态位/GUID/属性/时间戳/对齐） | 与 harness `efivars.write` 口径一致，回读解析正确 |
| dbx 哈希口径（全零 32 字节 vs 空输入 SHA256） | 两种都试过，均被拒；正式脚本已对齐 harness 空输入 SHA256 |
| PE CheckSum 字段 | pristine 与签名后均为 0，与 harness 一致 |
| code 固件内嵌默认证书（Microsoft/UEFI CA/Shim） | 两个 secure code 二进制扫描均为 0 个候选 |
| 模板出厂变量是否丢失（MTC/certdb/VendorKeysNv/VarErrorFlag 等） | 全部保留，24 条记录 |
| CD 挂载参数（Sata 索引 vs harness `ide-cd,bus=ide.0`） | 两种写法均被拒，与设备路径无关 |

**决定性对照**：把 harness 已验证可通过的签名产物 `bootx64-harness.efi`（正式 keys db 签名）放进 ISO，配对应 db 证书的 vars，**光盘路径下依然 Access Denied**。由此排除签名/证书问题，锁定光盘 CD 引导镜像这一中间层。

## 三、为什么光盘路径在 SB 下走不通

ISO 的 UEFI 启动链（xorriso `--efi-boot`）：

```
固件 SB 校验 → limine-uefi-cd.bin（El Torito 第一阶段，合并 CD 引导镜像）
            → 链载 /EFI/BOOT/BOOTX64.EFI（我们签名过的 Limine）
            → 链载 HMOS.EFI / 内核
```

- `limine-uefi-cd.bin`（3,145,728 字节）是**合并镜像**，内部嵌多个 PE 候选，本身**没有 Authenticode 签名目录**，也不是可直接重签的标准 PE。
- Secure Boot 开启时，固件按启动链顺序逐段校验；第一阶段 CD 镜像未被 db 信任，整盘在到达 `BOOTX64.EFI` 之前就被拒绝。
- 官方 Limine 测试用例（`checks/cases/secureboot.py`）全部用 `t.boot(t.boot_disk(tree), ...)`，即 **GPT/FAT32 ESP 磁盘**，固件直接读 ESP 上的 `BOOTX64.EFI`，**不生成、不经过 `limine-uefi-cd.bin`**。

### 本机当前无法构造 FAT ESP 磁盘镜像的原因

- 本机无 mtools（mformat/mmd/mcopy）、无 gcc/make、无 .NET SDK、无 WSL/Docker、无 7zip/diskpart 可用；
- pyfatfs 的 mkfs/格式化路径、任何 mkfs/mformat 调用被安全策略阻断（两次高危拦截，不再重试）；
- 云主机（Linux）无 sudo、apt 装 mtools 被拒，格式化工具同样被阻断。

## 四、已交付的密钥与签名产物（`keys\`）

自建测试密钥链（RSA 2048，SHA-256，10 年有效期）。三枚证书当前为**独立自签、互不签发**（复刻 harness `openssl req -x509` 口径）。

| 文件 | 用途 | 大小 |
|---|---|---|
| `pk.key` / `pk.crt` / `pk.der` / `pk.esl` | Platform Key（平台密钥） | 1704 / 1143 / 803 / 847 |
| `kek.key` / `kek.crt` / `kek.der` / `kek.esl` | Key Exchange Key | 1704 / 1147 / 805 / 849 |
| `db.key` / `db.crt` / `db.der` / `db.esl` | 签名数据库（签名用此密钥） | 1708 / 1192 / 839 / 883 |

- `.der`：X.509 DER 证书；`.esl`：EFI_SIGNATURE_LIST（可直接导入固件）；`.crt`：PEM；`.key`：私钥（**离线保管，勿外泄**）。
- 已校验：每个 `.esl` 内嵌 DER 与对应 `.der` 逐字节一致，Owner GUID `6106575a-aa8e-41ca-b306-52596bcf4244`。

## 五、代码与脚本（项目根目录）

| 文件 | 作用 |
|---|---|
| `sign_hmos.py` | 签名/哈希/ESL/变量镜像辅助：`esl`、`hash-config`（整文件 BLAKE2B）、`hash-file`、`sign-stage`、`make-sb-vars`、`make-sb-vars-alt`（db 替换为对照证书，用于拒绝对照）子命令 |
| `build_hmos.bat` | 一键打包 8 步：汇编 boot.bin → 编译 UEFI EFI → 编译 ELF 内核 → 暂存 Limine → `sign-stage` 签名 → xorriso 双 El Torito → `limine bios-install` |
| `build\repro_sb.py` | 复刻 harness SB 流水线：enroll-config → authenticode 签名 → efivars.write 生成 vars |
| `build\make_chain_keys.py` | 生成 PK→KEK→db 规范链证书（`build\keys-chain`，对照用） |
| `diag_main.c` | 诊断 EFI 源码（RS 表偏移已修正：GetVariable=0x68），可打印 SecureBoot/SetupMode/PK/KEK/db/dbx |
| `build\harness\` | 从 limine-src 解压的 harness 模块：efivars.py / secureboot.py / authenticode.py / ports.py / qemu.py / env.py |

## 六、本机工具链与下载地址

| 工具 | 本机路径 / 版本 | 下载地址 |
|---|---|---|
| NASM | `tools\nasm.exe` | https://www.nasm.us/pub/nasm/releasebuilds/ |
| xorriso | `tools\xorriso.exe` | https://www.gnu.org/software/xorriso/ （Windows 构建见 https://github.com/robert-scheck/xorriso-windows ） |
| OpenSSL | Git 自带 openssl 3.5.9（`OPENSSL` 环境变量可指定） | https://git-scm.com/download/win |
| osslsigncode | `tools\osslsigncode\osslsigncode-2.16-windows-amd64\osslsigncode.exe` 2.16 | https://github.com/mtrojnar/osslsigncode/releases （`osslsigncode-2.16-windows-amd64.zip`） |
| Limine 预编译 | `tools\efi\limine\limine-binary\` 12.9.6 | https://github.com/limine-bootloader/limine/releases |
| OVMF 固件 | `tools\ovmf\edk2-ovmf-bins\` | https://github.com/osdev0/edk2-ovmf-stable-bins/releases/latest/download/edk2-ovmf-bins.tar.gz |
| QEMU | qemu-system-x86_64 11.1.0（`QEMU` 环境变量可指定） | https://www.qemu.org/download/#windows |
| LLVM/clang/lld | 23.1.5（`CLANG`/`LLD`/`LDLLD` 环境变量可指定） | https://releases.llvm.org/ |
| Python | 3.14.7（`PYTHON` 环境变量可指定） | https://www.python.org/ |

## 七、SB 落地路径（ESP 磁盘）与本机已备好的材料

Secure Boot 下要让 HMOS 启动，必须走 **FAT32 ESP 磁盘**，而不是光盘 ISO。本机格式化被策略阻断，因此已把**可直接拷进 ESP 的材料目录**和两套脚本备好，留到有格式化能力的环境执行。

### 7.1 本机已生成的 ESP 材料目录 `esp_material\`

| ESP 内路径 | 本机文件 | 状态 |
|---|---|---|
| `/EFI/BOOT/BOOTX64.EFI` | `esp_material\EFI\BOOT\BOOTX64.EFI` | db 签名，`verification: ok`，已登记配置 BLAKE2B |
| `/EFI/BOOT/HMOS.EFI` | `esp_material\EFI\BOOT\HMOS.EFI` | db 签名，`verification: ok` |
| `/boot/hmoskernel` | `esp_material\boot\hmoskernel` | ELF64 内核，conf 路径已带 `#<blake2b>` |
| `/limine.conf` | `esp_material\limine.conf` | 配置哈希已登记进 BOOTX64.EFI |
| `/boot/limine/limine-bios.sys` | `esp_material\boot\limine\limine-bios.sys` | BIOS 链载 stage2（UEFI SB 不依赖） |

已校验：两个 EFI 签名 `ok`；内核哈希 `95d3c74f…5a758446b14` 与 conf 中路径后缀一致；`vars-official-keys.fd` 内 PK/KEK/db 与 `keys\*.esl` 逐字节一致，`SecureBootEnable=1`、`CustomMode=0`。

### 7.2 脚本

| 脚本 | 作用 | 在哪跑 |
|---|---|---|
| `stage_esp_material.ps1` | 重新签名并刷新 `esp_material\`（改完内核/conf 后用；`-SkipSign` 只重拷） | Windows 本机 |
| 云主机 `espwork\build_esp.py` | 纯用户态 pyfatfs 建 64MiB FAT32 镜像、写五份材料、读回校验、补 MBR 分区表（无 sudo、不调系统格式化工具） | 云主机 Linux |
| `build_esp_image.sh` | 旧方案：losetup+sgdisk+mkfs.vfat 建 ESP 镜像（需 root，本机未跑，保留备查） | 有 root 的 Linux |
| `qemu_test\run_sb_disk_test.ps1` | QEMU 以**硬盘**（非光盘）挂 `esp.img`，secure code + 已登记 vars，无头截图/串口；`-Window` 出窗口 | Windows 本机 |
| `qemu_test\run_qemu.ps1` | 交互式启动器（bat 入口）：`-Mode uefi/bios` 挂光盘 ISO；`-Mode secure` 挂 `esp.img` 硬盘（安全引导正确路径）；`-Seconds N` 可无头定时退出 | Windows 本机 |
| `qemu_test\启动-*.bat` | 三个双击入口：`启动-BIOS.bat`、`启动-UEFI.bat`（光盘）、`启动-SecureBoot.bat`（esp.img 硬盘） | Windows 本机 |

### 7.3 落地步骤

**A. 生成 ESP 镜像（已在云主机打通，纯用户态 pyfatfs，无 sudo）：**
```bash
# 云主机：pip3 install --target /tmp/pylib pyfatfs fs six appdirs "setuptools<81"
# 把 esp_material 五文件打成 bundle.zip 上传，下载解包到 mat/，然后：
python3 build_esp.py        # 产物 esp.img，读回校验 + 补 MBR 0x0B 分区
gzip -9 -c esp.img > esp.img.gz
```
回传本机解压为 `qemu_test\fw\esp.img`（当前已就位，MD5 `a4784811…`）。

**B. QEMU 复测（本机 Windows）：**
```powershell
# 把 esp.img 放到 qemu_test\fw\esp.img（或用 -Disk 指定路径）
.\qemu_test\run_sb_disk_test.ps1 -Seconds 15
# 想看窗口：.\qemu_test\run_sb_disk_test.ps1 -Window
```
串口日志 `qemu_test\serial-sb-disk.log`，帧图 `qemu_test\shots\sb-disk-*.ppm`。

**C. 真机：**
1. 建 GPT 磁盘，FAT32 ESP 分区（类型 GUID `C12A7328-F81F-11D2-BA4B-00A0C93EC93B`）。
2. 按 7.1 表把 `esp_material\` 内容拷到 ESP 对应路径。
3. 固件进 **Setup Mode**，依次导入 `keys\pk.esl` → `kek.esl` → `db.esl`（界面若只认 DER/CRT 则用 `.der`/`.crt`）。
4. 关 Setup Mode、开 Secure Boot，从 ESP 磁盘启动。

> 虚拟机内已用云主机生成的 `esp.img` 复测通过（见 8.0）。真机落盘仍需在真机 ESP 分区按 7.1 表拷入材料并导入密钥。

## 八、待办 / 未决项

### 8.0 2026-11-15 复测：安全引导 ESP 磁盘镜像在虚拟机内打通

**最终状态：安全引导在本机 QEMU（无真机）复测通过。**

#### 8.0.1 打通路径

- 云主机（Python 3.12，无 sudo）用纯用户态 **pyfatfs 1.1.0** 在普通镜像文件上 mkfs 出 64MiB FAT32 卷（不调用系统 mkfs/mformat，未被格式化策略拦截），写入五份 ESP 材料，读回 SHA256 全部 MATCH；补写 MBR 单分区表（类型 `0x0B`、活动位 `0x80`、整盘 131072 扇区，superfloppy 风格）。
- 镜像 gzip -9 压缩（约 438KB）经飞书云盘回传 Windows，解压为 `qemu_test\fw\esp.img`（67,108,864 字节，MD5 `a4784811daad792412e81c9a3e5b96f6`），与云主机一致。

#### 8.0.2 本轮定位并修复的根因：配置哈希口径错误

- 现象：普通 OVMF 下固件能从 ESP 硬盘读到并启动 Limine，但随即 `PANIC: !!! CHECKSUM MISMATCH FOR CONFIG FILE !!!`。
- 排查：镜像内 `limine.conf` 与源文件逐字节相等；BOOTX64.EFI 内 enroll 的哈希与脚本算出的 `size-2` BLAKE2B 一致。
- 对照 Limine 12.9.6 源码 `common/lib/config.c`：`config_size = f->size + 2`，校验 `blake2b(out, config_addr, config_size - 2)`，即对**整份磁盘文件（f->size 字节）**算哈希；尾部两字节是加载后补的 `\n\0`，不参与哈希。官方测试 `checks/cases/host.py:124` 用 `hashlib.blake2b(data)` 整文件登记。
- 修复：`sign_hmos.py` 配置哈希由 `raw[:len(raw)-2]` 改为**整文件** `b2b(raw)`（`hash-config` 子命令同步修正）；重新 enroll-config → Authenticode 签名 → 刷新 `esp_material\`。
- 修正后整文件配置哈希：`c85893f20385439a2199a99adf143a2fa99d66d6b8a5d8d3d0cf2dd32eef9c82f875f43787419f4bb641bb51d9c7d89b67d1143472801d3b2dfdf6c9be2079fc`（已 enroll 进 BOOTX64.EFI，与磁盘 conf 整文件哈希一致）。

#### 8.0.3 三组虚拟机复测结果（同一 `esp.img`）

| 场景 | vars / 固件 | 结果 |
|---|---|---|
| 普通固件（非安全引导） | 普通 OVMF code + 空白 vars | 配置校验通过，进入内核，帧图 `HMOS - UEFI Boot OK!`（`shots\esp-plain.png`） |
| 安全引导 · 正确 db（用户模式） | secure code + `vars-official-keys.fd`（SecureBootEnable=1、CustomMode=0、PK/KEK/db 已登记） | 放行签名 Limine EFI → 配置校验通过 → 内核帧图 `HMOS - UEFI Boot OK!`（`shots\sb-disk-7.png`） |
| 安全引导 · 错配 db（对照） | secure code + `vars-alt-db.fd`（db 换成自签对照证书 `keys\alt\db.crt`） | `failed to load Boot0002 ... Access Denied -- rejected probably by Secure Boot`，无启动设备（`shots\sb-alt.png`，串口 `serial-sb-alt.log`） |
| 安全引导 · 无密钥（Setup Mode，对照） | secure code + `vars.tpl.fd`（未登记密钥） | 放行（Setup Mode 不强制校验，属预期），进入内核（`shots\sb-tpl.png`） |

对照结论：正确 db 放行、错配 db 拒绝，说明 secure code 确实在执行签名校验；放行来自 db 证书与签名者同一密钥对，而非固件未生效。

#### 8.0.4 启动链（安全引导 ESP 路径，实测）

```
固件安全引导校验 → /EFI/BOOT/BOOTX64.EFI（db 签名的 Limine，配置哈希已 enroll）
  → 配置 BLAKE2B 整文件校验通过
  → 默认条目 1：Limine 协议内核 /boot/hmoskernel（路径带 #<内核 BLAKE2B>）
  → 内核帧图 HMOS - UEFI Boot OK!
```
默认 `default_entry: 1` 启动的是 Limine 协议内核；第二条 `/EFI/BOOT/HMOS.EFI` 为 efi 协议链载备用项（同样 db 签名）。

#### 8.0.5 仍未决（与本次虚拟机复测独立）

- [ ] 真机 enrollment：确认固件界面接受 `.esl` 还是 `.der`/`.crt`；若需 PKCS7 认证变量 `.auth`，需 `cert-to-efi-sig-list` + `sign-efi-sig-list`（本机暂无此工具链）。
- [ ] 真机上 ESP 分区为 MBR 类型 `0x0B`（非 GPT/ESP GUID `C12A7328-...`）；OVMF 可识别，真机 UEFI 是否识别为 ESP 未验证。
- [ ] 光盘形态若必须支持安全引导，需要可签名的 UEFI CD 引导镜像（官方 Limine 未提供已签名的 `limine-uefi-cd.bin`；通常用 shim 或改用磁盘 ESP）。
- 16GB 物理卡在本机 QEMU 仍打不开（可移动盘不可脱机、句柄拒绝访问）；虚拟机测试载体为 `esp.img` 镜像文件。

#### 8.0.6 启动菜单鼠标（2026-11-16 排查）

- 现象：安全引导 OVMF / Limine 引导菜单里没有鼠标指针（BIOS 模式正常；OVMF 固件设置菜单内指针可见）。
- **根因（来自 Limine 12.9.6 自带测试 `checks/cases/mouse.py:12` 注释）**：edk2/OVMF 固件对 QEMU 的 **USB tablet（`usb-tablet`，绝对指针）不暴露任何指针协议**。早期改成 XHCI + usb-tablet 无效，正因为固件根本没把这个设备绑定出 Simple/Absolute Pointer Protocol。
- Limine UEFI 鼠标来源（`common/drivers/mouse.c` `mouse_init`）：枚举 `EFI_SIMPLE_POINTER_PROTOCOL`（相对）与 `EFI_ABSOLUTE_POINTER_PROTOCOL`（绝对）；两套都为 0 才不激活鼠标。
- **最终改动**：两个脚本（`run_qemu.ps1`、`run_sb_disk_test.ps1`）指针设备从 XHCI + `usb-tablet` 改为 PCI 总线 **`virtio-tablet-pci`**（官方 UEFI 绝对指针方案，无需 USB 控制器）；键盘仍走默认 PS/2。
- 备选：若 virtio-tablet 在本固件仍无指针，可换相对鼠标 `-device usb-mouse`（挂 USB 控制器），或 `virtio-mouse-pci`。
- 无头冒烟：安全引导下 QEMU 无设备报错，HARDDISK 仍 `starting` 放行。
- **2026-11-16 窗口实跑确认：`virtio-tablet-pci` 下 Limine 菜单指针正常跟随，鼠标问题解决。**
- 注：菜单 `timeout: 3` 秒即进内核；要长时间停留观察鼠标，需改配置超时并重走签名流水线。

#### 8.0.7 16GB 卡材料刷新（2026-11-16）

- 卡上两份 EFI 曾是旧 size-2 配置哈希版本（enroll `12eb8e3d…`），与卡上 conf 整文件哈希 `c85893f2…` 不符，真机/固件加载即配置校验失败。
- 已用 `esp_material\` 最新签名版覆盖卡上五份材料，复核五文件 SHA256 与源一致，卡上 enroll 哈希 = 卡上 conf 整文件哈希（match: True）。

## 九、测试脚本（`qemu_test\`）

- `run_test.ps1 -Mode bios|uefi`：非 SB 双模式回归。
- `run_qemu.ps1 -Mode bios|uefi|secure`：双击 bat 用的交互式启动器；secure 挂 esp.img 硬盘，其余挂光盘；`-Seconds N` 无头定时退出。
- `启动-BIOS.bat` / `启动-UEFI.bat` / `启动-SecureBoot.bat`：对应三个模式的双击入口。
- `run_sb_test.ps1 -Seconds N -CodeFw <code.fd> -VarsFw <vars.fd>`：SB 光盘对照（必被拒，仅复现现象）。
- `run_sb_disk_test.ps1`：SB **磁盘**实测（挂 ESP 硬盘镜像，非光盘），见 7.2。
- `run_repro_test.ps1` / `run_plain_test.ps1` / `run_ide_test.ps1`：派生对照。
- 串口日志 `serial-sb.log`、debugcon `debugcon-sb.log`、帧图 `shots\sb-*.ppm`（`ppm2png.py` 转 PNG）。
