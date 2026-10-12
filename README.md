# FRPW

![Closed Source](https://img.shields.io/badge/source-closed--source-111111)
![Release](https://img.shields.io/badge/release-v1.0.1-2563eb)
![Platform](https://img.shields.io/badge/platform-Linux%20Server%20%7C%20Cross--platform%20Client-0f766e)
![License](https://img.shields.io/badge/license-commercial-dc2626)

FRPW 是面向内网穿透、端口映射和多节点转发的商业化管理平台。公开仓库只发布
经过构建和校验的发行文件、安装脚本与文档，不公开服务端、Agent 或节点源码。

服务端安装需要有效的**授权密钥**（`FRPW_LICENSE`），获取方式见下方「授权说明」；Agent、远程节点与客户端不需要授权密钥。

## v1.0.1 功能

- 管理后台按业务分组重排：业务运营 / 客户与资源 / 商业化 / 系统 / 账号安全，每个模块独立成页
- HTTP、TCP、UDP 隧道与公网端口映射
- 多租户用户控制台、独立管理员后台和账号隔离
- Agent、远程 Edge 节点、节点配置下发和自动同步
- 套餐、增值服务、余额、账单、订单和自动续费
- 卡密兑换：批量签发充值卡与套餐卡，用户自助兑换到余额或套餐周期
- 站内公告与签到激励：公告带未读角标与已读跟踪，每日签到奖励自动入账余额
- 站点用量记录：按天 / 隧道 / 节点 / 租户聚合的流量与请求统计，用户端和管理后台都有数据面板
- 码支付主通道、备用通道、Webhook 与线下汇款
- Windows、Linux、macOS 图形客户端发行包
- 服务端和客户端 SHA-256 完整性校验
- 管理端、用户端与登录页底部显示当前版本号并链接作者 GitHub（ccmaoxiong）

## 授权说明

FRPW 为**付费商业软件**。服务端安装前需要一枚授权密钥，形如：

```
FRPW-xxxxxxxx~xxxxxxxx~xxxx~........
```

获取授权请联系作者：<https://github.com/ccmaoxiong>

安装脚本内置 Ed25519 公钥，会在**下载任何文件之前**本地校验密钥：

- 未提供密钥 → 安装终止并提示购买
- 签名无效 / 密钥被篡改 → 安装终止
- 密钥已过期 → 安装终止并提示到期日

校验过程完全离线，不联网、不上传任何信息。密钥自带有效期，到期后重新签发即可续费。

### 服务端运行期授权

安装脚本负责安装期拦截，服务端二进制在运行期继续复验同一枚密钥：

| 环境变量 | 默认值 | 说明 |
| --- | --- | --- |
| `FRPW_LICENSE` | 空 | 内联授权密钥，优先级最高 |
| `FRPW_LICENSE_FILE` | `/etc/frpw/license.key` | 服务端启动时读取的密钥文件；一键安装会自动写入并注入 systemd |
| `FRPW_LICENSE_ENFORCEMENT` | `degrade` | `degrade`：过期/被吊销时仍启动但降级（新隧道上限 1 条、禁止新建订单）；`strict`：直接拒绝启动 |
| `FRPW_REVOCATION_URL` | 本仓库 main 分支的 `revocations.json` | 签名吊销列表，服务端每 24 小时同步一次 |

服务端启动时若密钥缺失或签名不符会直接退出，运行期每 6 小时重新验签。授权状态（`active` / `expiring` /
`expired` / `revoked` / `missing` / `invalid`）、客户名、到期日、密钥指纹和当前策略可在管理后台的
「授权与许可」面板查看，并可点击「重新校验」立即复验。请勿手工修改 `/etc/frpw/license.key` 或外传密钥。

## 一键安装服务端

支持 Linux amd64 / arm64。云主机使用 `root` 或具有 `sudo` 权限的账号执行，
把 `FRPW-你的授权密钥` 替换为实际密钥：

发行包为付费授权发行：**服务端**安装脚本在下载任何文件之前先验签授权密钥（`FRPW_LICENSE`，旧名 `FRPW_LICENSE_KEY`），密钥缺失、过期或签名不符即终止。Agent、远程节点与客户端不需要授权密钥。

```bash
curl --http1.1 -fsSL --retry 5 --retry-delay 2 --connect-timeout 15 -H "Accept: application/vnd.github.raw+json" "https://api.github.com/repos/ccmaoxiong/frpw/contents/scripts/install.sh?ref=v1.0.1" -o /tmp/frpw-install.sh && sudo FRPW_LICENSE="FRPW-你的授权密钥" sh /tmp/frpw-install.sh server
```

如果当前网络的流式下载经常中断，也可以先保存脚本再执行：

```bash
curl --http1.1 -fsSL --retry 5 --retry-delay 2 https://github.com/ccmaoxiong/frpw/releases/download/v1.0.1/install.sh -o /tmp/frpw-install.sh && sudo FRPW_LICENSE="FRPW-你的授权密钥" sh /tmp/frpw-install.sh server
```

### 国内镜像一键安装

国内网络推荐使用专用安装器（强制 IPv4，安装器内部自动在 `ghfast.top`、
`gh-proxy.com`、`ghproxy.net` 和 `gh.acmsz.top` 之间切换镜像，并在下载前先
校验授权密钥（仅服务端角色）、下载后校验 `SHA256SUMS`）：

```bash
curl -4 --http1.1 -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 -o /tmp/frpw-install-cn.sh "https://raw.githubusercontent.com/ccmaoxiong/frpw/v1.0.1/scripts/install-cn.sh" && sudo FRPW_LICENSE="FRPW-你的授权密钥" sh /tmp/frpw-install-cn.sh server
```

raw 入口不通时改用 ghfast 镜像：

```bash
curl -4 --http1.1 -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 -o /tmp/frpw-install-cn.sh "https://ghfast.top/https://github.com/ccmaoxiong/frpw/releases/download/v1.0.1/install-cn.sh" && sudo FRPW_LICENSE="FRPW-你的授权密钥" sh /tmp/frpw-install-cn.sh server
```

安装 Agent 或远程节点时，把最后的 `server` 改为 `agent` 或 `node`，并按下方说明
提供对应的 `FRPW_*` 环境变量。

如果内置镜像全部不可达（网络干扰时常见 `Empty reply from server` 或
`Connection reset`），可以先在服务器上测速，再用 `FRPW_CN_MIRROR_BASE_URL`
指定可用镜像。该变量支持多个镜像（空格分隔），按顺序尝试：

```bash
for m in https://ghfast.top https://gh-proxy.com https://ghproxy.net https://gh.acmsz.top; do printf "%s -> " "$m"; curl -4 --http1.1 -fsSL --connect-timeout 8 --max-time 20 -o /dev/null -w "%{http_code}\n" "$m/https://github.com/ccmaoxiong/frpw/releases/download/v1.0.1/SHA256SUMS" 2>/dev/null || echo FAIL; done
```

```bash
sudo FRPW_CN_MIRROR_BASE_URL="https://ghfast.top/https://github.com/ccmaoxiong/frpw/releases/download/v1.0.1 https://gh-proxy.com/https://github.com/ccmaoxiong/frpw/releases/download/v1.0.1" FRPW_LICENSE="FRPW-你的授权密钥" sh /tmp/frpw-install-cn.sh server
```

生产环境建议同时指定公网 Agent 地址、基础域名和公网 HTTP 端口：

```bash
curl --http1.1 -fsSL --retry 5 --retry-delay 2 --connect-timeout 15 -H "Accept: application/vnd.github.raw+json" "https://api.github.com/repos/ccmaoxiong/frpw/contents/scripts/install.sh?ref=v1.0.1" -o /tmp/frpw-install.sh && sudo env FRPW_LICENSE="FRPW-你的授权密钥" FRPW_AGENT_PUBLIC_ADDR="tunnel.example.com:7000" FRPW_BASE_DOMAIN="example.com" FRPW_PUBLIC_HTTP_PORT="8080" sh /tmp/frpw-install.sh server
```

安装完成后：

- 用户控制台：`http://<服务器IP>:9000`
- 管理后台：`http://<服务器IP>:9000/admin-panel`
- 默认管理员：`admin@example.com` / `admin12345`
- 默认用户：`user@example.com` / `user12345`

首次登录后立即修改默认密码。升级时重新执行相同命令会保留数据库和已有配置，
并同样需要一枚未过期的授权密钥。

### 安装 Agent（国内）

```bash
curl -4 --http1.1 -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 -o /tmp/frpw-install-cn.sh "https://raw.githubusercontent.com/ccmaoxiong/frpw/v1.0.1/scripts/install-cn.sh" && sudo env FRPW_SERVER="tunnel.example.com:7000" FRPW_CONTROL_PLANE="http://console.example.com:9000" FRPW_AGENT_TOKEN="管理端生成的令牌" FRPW_AGENT_ID="office-pc" sh /tmp/frpw-install-cn.sh agent
```

### 安装远程节点（国内）

```bash
curl -4 --http1.1 -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 -o /tmp/frpw-install-cn.sh "https://raw.githubusercontent.com/ccmaoxiong/frpw/v1.0.1/scripts/install-cn.sh" && sudo env FRPW_CONTROL_PLANE="http://console.example.com:9000" FRPW_NODE_TOKEN="节点创建时显示的令牌" FRPW_NODE_AGENT_ADDR=":7000" FRPW_NODE_PUBLIC_HTTP_PORT="8080" FRPW_NODE_BASE_DOMAIN="edge.example.com" sh /tmp/frpw-install-cn.sh node
```

## 安装 Agent

Agent 服务端仅支持 Linux。在需要发布内网服务的 Linux 机器上执行：

```bash
curl --http1.1 -fsSL --retry 5 --retry-delay 2 --connect-timeout 15 -H "Accept: application/vnd.github.raw+json" "https://api.github.com/repos/ccmaoxiong/frpw/contents/scripts/install.sh?ref=v1.0.1" -o /tmp/frpw-install.sh && sudo env FRPW_SERVER="tunnel.example.com:7000" FRPW_CONTROL_PLANE="http://console.example.com:9000" FRPW_AGENT_TOKEN="管理端生成的令牌" FRPW_AGENT_ID="office-pc" sh /tmp/frpw-install.sh agent
```

## 安装远程节点

```bash
curl --http1.1 -fsSL --retry 5 --retry-delay 2 --connect-timeout 15 -H "Accept: application/vnd.github.raw+json" "https://api.github.com/repos/ccmaoxiong/frpw/contents/scripts/install.sh?ref=v1.0.1" -o /tmp/frpw-install.sh && sudo env FRPW_CONTROL_PLANE="http://console.example.com:9000" FRPW_NODE_TOKEN="节点创建时显示的令牌" FRPW_NODE_AGENT_ADDR=":7000" FRPW_NODE_PUBLIC_HTTP_PORT="8080" FRPW_NODE_BASE_DOMAIN="edge.example.com" sh /tmp/frpw-install.sh node
```

## 离线安装（服务器无法访问外网）

当目标服务器完全无法访问 GitHub 及其镜像时，可在一台能上网的机器下载发行文件、
上传到服务器后离线安装。服务端离线安装同样需要授权密钥（Agent / 节点不需要），并会对每个文件做 SHA-256 校验。

1. 在能上网的机器下载以下文件（无需全部，按需选择）：

   - 必需：`install.sh`、`install-local.sh`、`SHA256SUMS`、`frpw-server-v1.0.1-linux-<arch>`
   - 可选（用户端「客户端接入」下载功能需要）：`frpw-client-v1.0.1-*`、`frpw-node-v1.0.1-linux-<arch>`

   下载地址：<https://github.com/ccmaoxiong/frpw/releases/tag/v1.0.1>

2. 上传到服务器同一目录，例如 `/root/frpw/`：

   ```bash
   scp install.sh install-local.sh SHA256SUMS frpw-server-v1.0.1-linux-amd64 root@<服务器IP>:/root/frpw/
   ```

3. 在服务器上的该目录内执行（ARM 服务器把文件名换成 `-arm64` 版本）：

   ```bash
   cd /root/frpw
   sudo FRPW_LICENSE="FRPW-你的授权密钥" sh install-local.sh server
   ```

`install-local.sh` 以自身所在目录为发行目录，服务端先校验授权密钥（Agent / 节点跳过），再逐个校验
`SHA256SUMS` 中的 SHA-256，任一文件缺失、损坏或不匹配都会中止安装。

## Windows 客户端

服务端、Agent 服务端和远程节点只发布 Linux 版本。Windows、Linux、macOS 作为图形客户端平台继续支持。
登录用户控制台后进入「客户端接入」，选择目标平台，即可下载已内置平台地址、节点和
同步策略的完整客户端 ZIP；Windows 解压后运行 `start.bat`，Linux/macOS 运行 `sh ./start.sh`。

## 公网端口

默认需要放行：

| 端口 | 用途 |
| --- | --- |
| `9000/tcp` | 用户控制台、管理后台和 REST API |
| `7000/tcp` | Agent 接入 |
| `8080/tcp` | HTTP 隧道公网入口 |
| `20000-20999/tcp` | TCP 隧道自动分配端口 |
| `20000-20999/udp` | UDP 隧道自动分配端口 |

远程节点还需要放行节点自身的 HTTP、HTTPS、Agent 和 TCP/UDP 端口池。

## 发行文件

`v1.0.1` Release 包含：

- Server：Linux amd64 / arm64（garble 混淆，字符串与符号名已打乱）
- Agent：Linux amd64 / arm64（garble 混淆）
- Client：Windows amd64、Linux amd64 / arm64、macOS amd64 / arm64
- Node：Linux amd64 / arm64（garble 混淆）
- `SHA256SUMS`
- `install.sh`：标准云端一键安装脚本（Server 需 `FRPW_LICENSE`；Agent / 节点不需要）
- `install-cn.sh`：国内镜像云端一键安装脚本（Server 需 `FRPW_LICENSE`；Agent / 节点不需要）
- `install-local.sh`：离线安装脚本，用于无法访问外网的服务器（Server 需 `FRPW_LICENSE`）
- `revocations.json`：已吊销授权的签名列表（仓库根目录，服务端每 24 小时同步）

所有发行二进制均提供 SHA-256 校验。安装脚本会在写入系统目录前验证下载文件。

Linux 服务端组件的二进制经 garble 混淆，体积相应变大（server 约 43 MB），不影响功能与性能特性。

## 自建镜像

### 标准安装脚本（install.sh）

如果使用对象存储、CDN 或内网软件源，可以设置：

```bash
export FRPW_DOWNLOAD_BASE_URL="https://download.example.com/frpw/v1.0.1"
```

该目录需要包含 Release 中的二进制与 `SHA256SUMS`。使用自建镜像时安装脚本不再访问 GitHub。

### 国内安装器（install-cn.sh）

`FRPW_CN_MIRROR_BASE_URL` 可指向自建镜像或任意可用的 GitHub 代理前缀，
支持多个值（空格分隔，按顺序尝试，任一成功即继续安装）：

```bash
export FRPW_CN_MIRROR_BASE_URL="https://mirror.example.com/frpw/v1.0.1 https://ghfast.top/https://github.com/ccmaoxiong/frpw/releases/download/v1.0.1"
```

每个镜像必须能提供：

- `SHA256SUMS`：其文件自身的 SHA-256 必须与安装器内置的期望值一致
  （防止镜像被篡改或缓存过期）
- `install.sh`：其 SHA-256 同样会被安装器校验后才会执行

镜像缓存了旧版本文件时会验证失败并自动切换到下一个镜像；可等待镜像刷新
或改用其它镜像。无论使用何种镜像，授权密钥校验都在本地完成；该校验只针对 Server 安装，Agent 与远程节点不校验授权。

安装器默认直接读取公开 Release，不依赖 GitHub API。仅在私有发行或显式设置
`FRPW_USE_GITHUB_API=1` 时，才先请求 GitHub API；拥有仓库读取权限时可同时
设置 `FRPW_TOKEN`。

## 许可

本项目为闭源商业软件，**需付费授权使用**。公开仓库中的文档、安装脚本和发行
二进制仅可用于合法的授权部署。未经书面许可，不得复制、修改、反向工程、
再分发或用于派生商业产品。完整条款见 [LICENSE](LICENSE)。
