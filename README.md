# FRPW

![Closed Source](https://img.shields.io/badge/source-closed--source-111111)
![Release](https://img.shields.io/badge/release-v1.0.0-2563eb)
![Platform](https://img.shields.io/badge/platform-Linux%20Server%20%7C%20Cross--platform%20Client-0f766e)

FRPW 是面向内网穿透、端口映射和多节点转发的商业化管理平台。公开仓库只发布
经过构建和校验的发行文件、安装脚本与文档，不公开服务端、Agent 或节点源码。

## v1.0.0 功能

- HTTP、TCP、UDP 隧道与公网端口映射
- 多租户用户控制台、独立管理员后台和账号隔离
- Agent、远程 Edge 节点、节点配置下发和自动同步
- 套餐、增值服务、余额、账单、订单和自动续费
- 码支付主通道、备用通道、Webhook 与线下汇款
- Windows、Linux、macOS 图形客户端发行包
- 服务端和客户端 SHA-256 完整性校验

## 一键安装服务端

支持 Linux amd64 / arm64。云主机使用 `root` 或具有 `sudo` 权限的账号执行：

```bash
curl --http1.1 -fsSL --retry 5 --retry-delay 2 --connect-timeout 15 \
  https://github.com/ccmaoxiong/frpw/releases/download/v1.0.0/install.sh \
  | sudo sh -s -- server
```

如果当前网络的流式下载经常中断，也可以先保存脚本再执行：

```bash
curl --http1.1 -fsSL --retry 5 --retry-delay 2 \
  https://github.com/ccmaoxiong/frpw/releases/download/v1.0.0/install.sh \
  -o /tmp/frpw-install.sh
sudo sh /tmp/frpw-install.sh server
```

生产环境建议同时指定公网 Agent 地址、基础域名和公网 HTTP 端口：

```bash
curl --http1.1 -fsSL --retry 5 --retry-delay 2 --connect-timeout 15 \
  https://github.com/ccmaoxiong/frpw/releases/download/v1.0.0/install.sh \
  | sudo env \
      FRPW_AGENT_PUBLIC_ADDR="tunnel.example.com:7000" \
      FRPW_BASE_DOMAIN="example.com" \
      FRPW_PUBLIC_HTTP_PORT="8080" \
      sh -s -- server
```

安装完成后：

- 用户控制台：`http://<服务器IP>:9000`
- 管理后台：`http://<服务器IP>:9000/admin-panel`
- 默认管理员：`admin@example.com` / `admin12345`
- 默认用户：`user@example.com` / `user12345`

首次登录后立即修改默认密码。升级时重新执行相同命令会保留数据库和已有配置。

## 安装 Agent

Agent 服务端仅支持 Linux。在需要发布内网服务的 Linux 机器上执行：

```bash
curl --http1.1 -fsSL --retry 5 --retry-delay 2 --connect-timeout 15 \
  https://github.com/ccmaoxiong/frpw/releases/download/v1.0.0/install.sh \
  | sudo env \
      FRPW_SERVER="tunnel.example.com:7000" \
      FRPW_CONTROL_PLANE="http://console.example.com:9000" \
      FRPW_AGENT_TOKEN="管理端生成的令牌" \
      FRPW_AGENT_ID="office-pc" \
      sh -s -- agent
```

## 安装远程节点

```bash
curl --http1.1 -fsSL --retry 5 --retry-delay 2 --connect-timeout 15 \
  https://github.com/ccmaoxiong/frpw/releases/download/v1.0.0/install.sh \
  | sudo env \
      FRPW_CONTROL_PLANE="http://console.example.com:9000" \
      FRPW_NODE_TOKEN="节点创建时显示的令牌" \
      FRPW_NODE_AGENT_ADDR=":7000" \
      FRPW_NODE_PUBLIC_HTTP_PORT="8080" \
      FRPW_NODE_BASE_DOMAIN="edge.example.com" \
      sh -s -- node
```

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

`v1.0.0` Release 包含：

- Server：Linux amd64 / arm64
- Agent：Linux amd64 / arm64
- Client：Windows amd64、Linux amd64 / arm64、macOS amd64 / arm64
- Node：Linux amd64 / arm64
- `SHA256SUMS`
- Linux 一键安装脚本

所有发行二进制均提供 SHA-256 校验。安装脚本会在写入系统目录前验证下载文件。

## 自建镜像

如果使用对象存储、CDN 或内网软件源，可以设置：

```bash
export FRPW_DOWNLOAD_BASE_URL="https://download.example.com/frpw/v1.0.0"
```

该目录需要包含 Release 中的二进制与 `SHA256SUMS`。使用自建镜像时安装脚本不再访问 GitHub。

安装器默认直接读取公开 Release，不依赖 GitHub API。仅在私有发行或显式设置
`FRPW_USE_GITHUB_API=1` 时，才先请求 GitHub API；拥有仓库读取权限时可同时
设置 `FRPW_TOKEN`。

## 许可

本项目为闭源商业软件。公开仓库中的文档、安装脚本和发行二进制仅可用于
合法的授权部署。未经书面许可，不得复制、修改、反向工程、再分发或用于
派生商业产品。完整条款见 [LICENSE](LICENSE)。
