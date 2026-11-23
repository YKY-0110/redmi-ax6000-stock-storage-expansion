# 红米 AX6000（RB06）原厂固件扩容教程｜合并 mtd9 和 mtd10，创建 80 MiB `/data` 大分区

适用于 RB06 原厂 1.0.67，已能用 root 登录 SSH，且 `ft_mode=0`。最终从 `mtd8` 启动小米系统，把原 `mtd9` 的 30 MiB 和 `mtd10` 的 50 MiB 合成新的 `overlay`。

**`start` 会擦写原 `mtd9+mtd10`，原备用系统将被覆盖。** 擦写中断时仅靠 SSH 可能无法恢复。先把备份下载到电脑并核对 MD5。任一步报错都停在该步，保留当前 SSH。

## 0. 提取原厂固件并生成 FIT

电脑准备 Python 3.10 或更新版本和完整的 7-Zip。下载并解压仓库源码后，在电脑终端进入解压目录，把所有 SCP 命令中的路由器IP替换为你平时使用的 SSH 地址。`SOURCE-SHA256SUMS` 可用于校验包内源码。 [7-Zip 官方下载](https://www.7-zip.org/download.html)

```console
scp -O rb06-extract-original.sh root@路由器IP:/tmp/
```

在仍使用原布局和原厂固件的路由器上执行。脚本仅从当前系统的 `kernel`、`rootfs` 两个 UBI 卷读取，输出写到 RAM 中的 `/tmp/rb06-source/`。

```sh
sh /tmp/rb06-extract-original.sh
```

在电脑上建立目录并下载原厂卷。

```console
mkdir original
scp -O root@路由器IP:/tmp/rb06-source/kernel.fit original/
scp -O root@路由器IP:/tmp/rb06-source/rootfs.squashfs original/
```

Windows 用 PowerShell 生成。按实际安装位置修改 7-Zip 路径。

```powershell
python tools/build_fits.py --kernel original/kernel.fit --rootfs original/rootfs.squashfs --7zip 'C:/Program Files/7-Zip/7z.exe' --output-dir built
```

Linux 用终端生成。如果安装的命令叫 `7z`，把下面的 `7zz` 换成它。

```sh
python3 tools/build_fits.py --kernel original/kernel.fit --rootfs original/rootfs.squashfs --7zip 7zz --output-dir built
```

生成器会核对输入的长度和 SHA-256，并核对三份输出的 SHA-256。即使版本号相同，SHA-256 不一致也要停止。后续命令使用 `built/` 下的三份 FIT。

## 1. 核对布局并备份

在路由器 SSH 执行。原表应有 30 MiB 的 `mtd8 ubi`、30 MiB 的 `mtd9 ubi1` 和 50 MiB 的 `mtd10 overlay`。`firmware=0` 对应 `mtd8`，`firmware=1` 对应 `mtd9`。

```sh
cat /proc/cmdline
cat /proc/mtd
cat /proc/xiaoqiang/ft_mode
(
  set -e
  grep -q ' /tmp tmpfs ' /proc/mounts
  grep -q ' /data ubifs ' /proc/mounts
  test "$(cat /sys/class/ubi/ubi1/mtd_num)" = 10
  umask 077
  tar -czf /tmp/rb06-data-before-merge.tar.gz -C /data .
  tar -tzf /tmp/rb06-data-before-merge.tar.gz >/dev/null
  md5sum /tmp/rb06-data-before-merge.tar.gz
)
```

在电脑下载初始备份并核对两端 MD5。

```console
scp -O root@路由器IP:/tmp/rb06-data-before-merge.tar.gz .
```

Windows 用 `Get-FileHash rb06-data-before-merge.tar.gz -Algorithm MD5`，Linux 用 `md5sum rb06-data-before-merge.tar.gz`。

## 2. 验证 RAM 启动和回退

当前为 `firmware=1` 时，先从电脑上传脚本，再在 SSH 执行 `switch-8`。见到 `MTD8_ORIGINAL_TRIAL_ARMED` 才 `reboot`。确认 `firmware=0`、原 SSH 和后台正常、`/data` 来自 `mtd10`。已经在 `mtd8` 时跳过这次切槽。

```console
scp -O rb06-ram-boot-trial.sh root@路由器IP:/tmp/
```

```sh
sh /tmp/rb06-ram-boot-trial.sh switch-8
```

从 `mtd8` 上传并安排试启动。每次重启会清空 `/tmp`，所以要重新上传脚本。

```console
scp -O rb06-ram-boot-trial.sh built/RB06-1.0.67-ram-boot-test.fit root@路由器IP:/tmp/
```

```sh
sh /tmp/rb06-ram-boot-trial.sh stage-9
```

见到 `MTD9_RAM_TRIAL_ARMED` 才重启。用原认证方式登录，确认 `firmware=1`、标记 `RB06-1.0.67-RAM-PROBE`、日志两条 `PASS`、根目录来自 loop 上的 SquashFS，以及 `/data` 为 tmpfs。UBI 列表里应没有 `mtd9` 或 `mtd10`。

```sh
cat /proc/cmdline
tr -d '\000' </sys/firmware/devicetree/base/chosen/rb06-fit-probe
echo
cat /mnt/rb06-ram-probe.log
awk '$2=="/" || $2=="/data" {print}' /proc/mounts
cat /sys/class/ubi/ubi*/mtd_num 2>/dev/null || :
nvram get flag_last_success
nvram get flag_ota_reboot
nvram get flag_boot_success
```

三个回退标志依次为 `0`、`1`、`0` 时，直接 `reboot`。重连后确认 `firmware=0`，且 `cat /sys/class/ubi/ubi1/mtd_num` 输出 `10`。测试 FIT 设有约十分钟的重启计时器。

## 3. 启动正式迁移版

从 `mtd8` 上传文件并执行 `stage-migrate`。看到 `MTD9_RAM_MIGRATION_ARMED` 才重启。

```console
scp -O rb06-ram-boot-trial.sh built/RB06-1.0.67-ram-overlay80-migrate.fit root@路由器IP:/tmp/
```

```sh
sh /tmp/rb06-ram-boot-trial.sh stage-migrate
```

用原 SSH 重连后，确认 `firmware=1`、标记 `RB06-1.0.67-RAM-OVERLAY80-MIGRATE` 和日志两条 `PASS`，然后尽快执行第 4 步的 `prepare`，以暂停约十分钟的试启动计时器。

```sh
cat /proc/cmdline
tr -d '\000' </sys/firmware/devicetree/base/chosen/rb06-fit-probe
echo
cat /mnt/rb06-ram-probe.log
```

## 4. 核对映射和正式备份

上传迁移脚本和最终 FIT，再运行 `prepare`。它暂停自动重启，检查 80 MiB 入口，并从原始只读 `mtd10` 生成归档。

```console
scp -O rb06-ram-overlay80-migrate.sh built/RB06-1.0.67-overlay80-test.fit root@路由器IP:/tmp/
```

```sh
(
  set -e
  mkdir -m 700 -p /tmp/rb06-migrate
  mv /tmp/RB06-1.0.67-overlay80-test.fit /tmp/rb06-migrate/final.fit
  sh /tmp/rb06-ram-overlay80-migrate.sh prepare
)
```

看到 `ALIAS_OPEN_RDWR_OK` 和 `READY_BEFORE_ERASE` 后，下载归档，核对并保存两端一致的 MD5。后续验收用这份 `original-data.tar.gz`。

```console
scp -O root@路由器IP:/tmp/rb06-migrate/original-data.tar.gz .
```

Windows 用 `Get-FileHash original-data.tar.gz -Algorithm MD5`，Linux 用 `md5sum original-data.tar.gz`。

## 5. 正式合并

在 SSH 中验证原厂 `procd` 能启动后台任务。这个探针只在 RAM 中写日志。

```sh
sh /tmp/rb06-ram-overlay80-migrate.sh probe-launch
```

**确认 `PROCD_LAUNCH_OK`、`READY_BEFORE_ERASE` 和电脑备份 MD5 后才执行 `start`。** 用第 4 步的实际 MD5 替换占位文字。

```sh
sh /tmp/rb06-ram-overlay80-migrate.sh start '电脑备份的MD5'
```

看到 `Migration submitted to procd` 后查看日志。如果日志文件还没创建，稍等再执行 `tail`。

```sh
tail -f /tmp/rb06-migrate/migration.log
```

脚本先暂存 `mtd8` 的最终 FIT，再重建 80 MiB 数据卷。恢复、重新挂载并校验 `/data` 后才切换启动 FIT，随后自动重启。成功日志包含 `80 MiB /data verified and final mtd8 FIT selected`。

出现 `Stopped` 或 `Rollback failed` 时，保留 RAM 会话和 `/tmp` 备份，先查看日志。恢复阶段失败时，脚本会尝试重建原 50 MiB 数据卷并校验，再启动原 `mtd8`。

## 6. 验收

重连后整段执行。`ubi0` 应映射到 `mtd8`，`ubi1` 应映射到合并后的 `mtd9`，`/data` 应为读写 UBIFS。

```sh
(
  set -e
  grep -E '(^| )firmware=0( |$)' /proc/cmdline
  test "$(cat /sys/class/ubi/ubi0/mtd_num)" = 8
  grep -E '^mtd9:[[:space:]]+05000000[[:space:]]+00020000[[:space:]]+"overlay"$' /proc/mtd
  test "$(cat /sys/class/ubi/ubi1/mtd_num)" = 9
  grep -E '^ubi1_0 /data ubifs rw(,| )' /proc/mounts
  test "$(stat -c '%d:%i' /etc/config)" = "$(stat -c '%d:%i' /data/etc/config)"
  ubinfo /dev/ubi1_0
  df -h /data
  echo 'PASS: mtd8 boot, 80 MiB overlay, and live configuration binding verified'
)
```

`80 MiB` 是原始分区容量，`df -h /data` 显示的是扣除 UBI 和 UBIFS 开销后的文件系统容量。

用第 4 步的归档逐文件核对配置，再实测原 SSH 认证和小米后台。脚本核对内容、链接、权限和属主。

```console
scp -O rb06-overlay80-check-config.sh original-data.tar.gz root@路由器IP:/tmp/
```

```sh
sh /tmp/rb06-overlay80-check-config.sh /tmp/original-data.tar.gz '第4步保存的MD5'
```

如果归档 MD5 不一致，重新上传第 4 步下载的原归档，再用当时记录的 MD5 核对。

如果脚本列出差异，先看路径。确认仅有日志、缓存等运行文件在重启后变化，可以接受。若涉及配置、SSH 授权文件，或有配置项缺失、权限或属主有变，先查清差异，再确认能用原有凭据登录 SSH 和小米后台。

如果备份已删、只剩 MD5，跳过上传归档和逐文件校验。MD5 只能核对手中的原归档，无法用来确认现有配置逐项一致。用本节前面的命令确认从 mtd8 启动、合并后的 80 MiB 分区已挂载为可读写的 /data，且 /etc/config 指向 /data/etc/config。再用原有凭据登录 SSH 和小米后台，核对原先使用的 Wi-Fi、联网和 DHCP 等设置。
