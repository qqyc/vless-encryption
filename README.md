# vless-encryption

Xray VLESS Encryption 安装与管理脚本。

当前版本：`v26.09.27-qqyc.1`（基于上游 v26.09.27 的最小兼容补丁）

支持两种模式：

- VLESS Encryption：自身加密，不加 TLS 外层；`security=none` 不代表明文。无需 SNI。
- VLESS Encryption + REALITY：在前者基础上增加 TLS 外观，需要 SNI 目标域名。

两者均使用 Vision（`xtls-rprx-vision`）。需要 TLS 外观选 REALITY；SNI 须从服务器可达、支持 TLS 1.3（443），无需自有域名或证书。

客户端及其内核须支持 VLESS Encryption，并能导入链接中的 `encryption` 参数；仅支持普通 VLESS/REALITY 的客户端不适用。

需要 root 权限和 systemd，脚本会自动补齐下载、JSON、校验、进程及端口检查工具。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/qqyc/vless-encryption/main/install.sh)
```

## 无交互安装

VLESS Encryption：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/qqyc/vless-encryption/main/install.sh) install --port 12345
```

VLESS Encryption + REALITY + Vision：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/qqyc/vless-encryption/main/install.sh) install --port 12345 --sni www.sega.com
```

参数：

```text
--port <端口>              默认 443
--uuid <UUID>              自动生成
--auth <mlkem768|x25519>   默认 mlkem768
--mode <native|xorpub|random> 默认 native
--sni <域名>               启用 REALITY + Vision
--short-id <十六进制 ID>   默认 20220701，仅 REALITY 可用
--address <IP或域名>       指定并保存节点连接地址，支持 IPv4 / IPv6 / 域名
--reinstall                明确允许重装已有节点（覆盖配置并重新生成密钥）
```

不带 `--sni` 安装 VLESS Encryption，带 `--sni` 安装 REALITY 模式。Short ID 为 2–16 位偶数长度十六进制。

已有配置时，交互重装必须确认；非交互重装必须添加 `--reinstall`。更新核心或修改现有参数请使用菜单，不要重新执行 `install`。

修改已有节点的连接地址可以运行 `bash install.sh --address 203.0.113.10` 进入菜单，然后查看订阅以保存地址；不会因此修改 UUID 或密钥。地址优先级：本次指定值 > 已保存值 > 自动检测。连接地址不是 REALITY SNI；纯 Encryption 模式仍无需域名。

认证：默认 `mlkem768`（ML-KEM-768，后量子）；`x25519` 密钥更短、非后量子。两者均使用 `mlkem768x25519plus` 后量子密钥交换，密钥不可混用。

外观：`native` 原始格式（默认），`xorpub` 混淆公钥部分，`random` 全随机外观；客户端须与服务端一致。

## 管理

直接运行脚本进入菜单，可执行安装、更新、重启、卸载、修改配置和查看订阅。

安装或重装会覆盖 Xray 配置；修改参数或切换模式只更新首个入站的相关字段，保留监听地址及其他自定义配置。卸载会调用官方 `remove --purge`，仅残留文件时直接清理；先确认受管进程停止，再删除配置、日志和客户端信息，全部成功后才删除本脚本。回滚失败的快照保留并显示路径，同一会话禁止覆盖恢复基准，须先手动恢复并清理快照。启动检查确认真实主进程持续运行，不代替远程连通性验证。

保留模式修改会保留加密密钥；切换模式会按默认 `mlkem768/native` 重新生成密钥，须重新导入节点链接。修改 SNI 会同步更新目标为该域名的 443 端口。请自行放行节点端口。

## 文件与日志

- 配置：`/usr/local/etc/xray/config.json`
- 客户端 Encryption 参数：`/root/xray_encryption_info.txt`
- 旧 qqyc fork 若存在 `/var/lib/vless-encryption/client-encryption`，优先沿用该文件；配置写入和回滚也使用同一文件，不读取可能过期的 `/root` 密钥，不自动换密钥。
- 指定的节点连接地址：`/var/lib/vless-encryption/server-address`（也兼容旧 fork 的保存值）
- REALITY 客户端信息：`/root/xray_reality_info.txt`
- 节点链接：`/root/xray_vless_link.txt`
- 实时日志：`journalctl -u xray -f --no-pager`，按 Ctrl+C 退出。

## 检查脚本

```bash
bash -n install.sh
shellcheck install.sh
python3 tests/regression.py
XRAY_TEST_BINARY=/path/to/xray python3 tests/connectivity.py
```

GitHub Actions 在 Linux 上运行语法检查、ShellCheck、回归测试以及真实的本机客户端—服务端握手（两种认证 × 三种流量外观，另验证错误 UUID 被拒绝）。测试核心固定为官方 v26.3.27 并校验 SHA256；不安装系统服务，也不代替实际服务器的防火墙与远程连通性检查。
