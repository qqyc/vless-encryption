# vless-encryption

面向当前 Xray 的 VLESS Encryption 安装与管理脚本。默认配置为：

- VLESS Encryption（`mlkem768x25519plus`）
- ML-KEM-768 服务端认证密钥
- `native` 流量外观
- 客户端 0-RTT / 服务端 600 秒会话票据
- `xtls-rprx-vision`
- RAW/TCP，底层传输安全为 `none`
- 直接使用服务器公网 IP，无需域名、证书或 SNI

> [!IMPORTANT]
> VLESS Encryption 仍在快速演进，客户端必须支持该协议和当前分享链接格式。它不是 TLS/REALITY 的通用替代品，也不保证适合所有网络环境。请先在测试环境验证。

## 这次重构修复了什么

- 将旧版入站配置的 `settings.clients` 更新为当前 Xray 使用的 `settings.users`。
- `update` 会识别本项目旧配置，并自动迁移；旧配置和客户端密钥仍可读取。
- 写入前运行 `xray run -test`，写入采用临时文件；服务启动失败时自动回滚。
- 每次替换主配置前保存带时间戳的备份。
- 客户端凭据改存于 `/var/lib/vless-encryption/`，目录权限为 `0700`、文件为 `0600`。
- 官方安装器先下载、检查来源特征，再作为本地文件执行；下载启用 HTTPS、重试和失败检测。
- 修复参数缺失、端口、UUID、IPv4/IPv6、URL 转义和非交互模式的校验。
- 不再重复下载 GeoIP/GeoSite，也不再依赖 GitHub API 查询版本。
- 新增 `status`、`config`、`link` 等清晰的子命令和自动化测试。

## 支持环境

- Debian / Ubuntu（`apt-get`）
- Fedora / RHEL / Rocky / AlmaLinux（`dnf` 或 `yum`）
- systemd
- root 权限

脚本会按需安装 `curl`、`jq` 和 CA 证书。Xray 核心由官方 [XTLS/Xray-install](https://github.com/XTLS/Xray-install) 安装器负责安装和更新。

## 安装

建议先下载并检查脚本：

```bash
curl -fL --proto '=https' --tlsv1.2 \
  -o install.sh \
  https://raw.githubusercontent.com/qqyc/vless-encryption/main/install.sh
less install.sh
sudo bash install.sh install --port 443
```

脚本会自动检测服务器公网 IPv4（没有 IPv4 时再尝试 IPv6），因此安装时无需提供域名。`--address` 只是在公网 IP 自动检测不正确时，覆盖客户端分享链接中的连接地址；它不会写入 Xray 服务端配置，也不会启用域名、TLS、证书或 SNI。

也可以打开交互式菜单：

```bash
sudo bash install.sh
```

非交互安装：

```bash
sudo bash install.sh install \
  --port 8443 \
  --uuid d0f6a483-51b3-44eb-94b6-1f5fc9272c81 \
  --yes
```

只让标准输出包含客户端链接，便于自动化接收：

```bash
link="$(sudo bash install.sh install --port 443 --yes --quiet)"
```

## 更新旧安装

先用新版脚本执行：

```bash
sudo bash install.sh update
```

如果检测到本项目旧版生成的单入站配置，脚本会把 `clients` 迁移为 `users`，并把旧的 `/root/xray_encryption_info.txt` 迁移到受限状态目录。修改前的主配置保存在：

```text
/usr/local/etc/xray/config.json.bak.<UTC时间>.<进程号>
```

对于自行维护的复杂 Xray 配置，`update` 只更新核心并验证现有配置，不会擅自改写结构。

## 常用命令

```bash
# 查看状态
sudo bash install.sh status

# 更新 Xray
sudo bash install.sh update

# 修改端口（保留 UUID 和加密密钥）
sudo bash install.sh config --port 2053

# 修改 UUID
sudo bash install.sh config --uuid d0f6a483-51b3-44eb-94b6-1f5fc9272c81

# 轮换加密密钥；原客户端链接会立即失效
sudo bash install.sh config --rotate-keys

# 公网 IP 自动检测不正确时，用真实服务器 IP 覆盖分享链接地址
sudo bash install.sh link --address YOUR_SERVER_IP

# 查看日志
sudo bash install.sh logs

# 卸载
sudo bash install.sh uninstall
```

完整参数：

```bash
bash install.sh --help
```

## 安全与运维提示

- 分享链接同时包含 UUID 和客户端 encryption 凭据，应按密码管理。
- 配置会监听 IPv4/IPv6 全部地址；请自行在云防火墙和系统防火墙中只开放所需端口。
- `install`/重装会生成新的 VLESS Encryption 密钥，现有客户端需要重新导入链接。
- `config --rotate-keys` 也会让现有客户端失效；仅修改端口或 UUID 时不会轮换密钥。
- 配置文件包含服务端认证私钥。脚本会将其设置为 `root` 与 Xray 服务组可读，而不是全局可读。
- 不要把生成的配置、状态目录或客户端链接提交到公开仓库。

## 开发与测试

```bash
bash -n install.sh
bash tests/run.sh
shellcheck install.sh tests/run.sh
```

测试不安装或启动 Xray，只检查关键解析、配置结构、参数校验和分享链接生成逻辑。
