# PROJECT_MEMORY.md — RustDesk 私有远控中枢架构活文档

> **法定版权**：Copyright (c) 2026 Yy1 (yuan278501381). All rights reserved. | MIT License | [GitHub](https://github.com/yuan278501381)

---

## 1. 核心架构拓扑与服务端部署状态 (Architecture & Server Topology)

本项目基于开源 [`rustdesk/rustdesk`](https://github.com/rustdesk/rustdesk) 构建企业级私有远程桌面体系，彻底替代商业收费版 ToDesk / 向日葵，专门服务于 **客户 Windows Server 服务器、Windows 虚拟机及客户办公 PC** 的远程实施与运维支持。

### 华为云 Windows ECS 私有中继中枢
* **宿主服务器**：`prod-chosen-huaweiyun01`
  * 公网 IP：`121.37.210.146`
  * 绑定主域名：`chosen.sh.cn`
  * 操作系统：Windows Server 2016 Standard (Build 14393)
  * SSH 管理通道：`ssh -i C:\Users\yuan2\.ssh\id_ed25519_codex Administrator@121.37.210.146`
* **服务端核心组件 (`rustdesk-server v1.1.16`)**：
  * 安装路径：`C:\RustDeskServer\`（包含 `hbbs.exe`、`hbbr.exe`、`rustdesk-utils.exe`）
  * 密钥持久化与灾备：
    * 运行期密钥：`C:\RustDeskServer\id_ed25519`（私钥）与 `C:\RustDeskServer\id_ed25519.pub`（公钥）
    * 华为云数据盘冷备：`D:\certs\rustdesk_server_keys\`
    * 本地分发目录冷备：`C:\repo\RustDesk\dist\id_ed25519*`
  * **专属公钥 (`Key`)**：`kjr789wzgnShiHvE0TK3P9a1jSLe1t6nG80PjhzoEXY=`
  * **安全启动模式**：强制附加 `-r chosen.sh.cn -k _` 参数（自动向客户端下发默认中继域名 `chosen.sh.cn`，并拒绝一切未携带专属公钥的连接与中继请求，彻底杜绝公网扫描器白嫖服务器带宽）。
* **Windows 后台常驻守护（计划任务）**：
  * `RustDesk-hbbs`：以 `NT AUTHORITY\SYSTEM` `ServiceAccount` 最高权限运行 `C:\RustDeskServer\run_hbbs.cmd`（内含 `ALWAYS_USE_RELAY=Y` 与 `hbbs.exe -r chosen.sh.cn:21117 -k _`），开机自启（`AtStartup`）+ 异常每分钟自动拉起（`RestartCount=999`）。
  * `RustDesk-hbbr`：以 `NT AUTHORITY\SYSTEM` `ServiceAccount` 最高权限运行 `C:\RustDeskServer\run_hbbr.cmd`（`hbbr.exe -k _`），开机自启（`AtStartup`）+ 异常每分钟自动拉起（`RestartCount=999`）。
* **防火墙与华为云安全组端口矩阵（已全链路实测打通）**：
  * 华为云安全组：`Sys-WebServer` (`875f908f-7748-441a-945a-d9701d42089c`，Region `cn-south-1`)，已通过华为云 VPC API 自动补齐 `UDP 21116` 及 `TCP 21114-21119` 入站规则。
  * `TCP 21115`：`hbbs` NAT 类型探测（实测 `0 ms` 连通）
  * `TCP 21116`：`hbbs` TCP P2P 打洞与连接控制（实测 `0 ms` 连通）
  * `UDP 21116`：`hbbs` ID 注册与心跳保活（实测 Protobuf `RegisterPeer` 往返回包 `3A-02-10-01` 正常）
  * `TCP 21117`：`hbbr` 加密流中继服务（实测 `0 ms` 连通）
  * Windows 防火墙规则名：`RustDesk-Server-TCP`、`RustDesk-Server-UDP`

---

## 2. 客户端零配置交付规范与自动化运维脚本 (Zero-Config Delivery & Automation)

基于本仓库 [`src/custom_server.rs`](file:///c:/repo/RustDesk/src/custom_server.rs)、[`src/platform/windows.rs`](file:///c:/repo/RustDesk/src/platform/windows.rs) 与 [`libs/portable/src/main.rs`](file:///c:/repo/RustDesk/libs/portable/src/main.rs) 的配置注入机制，已在 [`C:\repo\RustDesk\dist\`](file:///c:/repo/RustDesk/dist) 下构建好双版本交付包与全自动运维脚本：

### A. 客户端双轨交付包（均已默认注入 `-qs-` / `--quick_support` 自动 SYSTEM 提权）
1. **纯中文短文件名版（内置配置防篡改 + 自动 SYSTEM 便携服务）**：
   * 路径：[`C:\repo\RustDesk\dist\上海逐城远程协助.exe`](file:///c:/repo/RustDesk/dist/%E4%B8%8A%E6%B5%B7%E9%80%90%E5%9F%8E%E8%BF%9C%E7%A8%8B%E5%8D%8F%E5%8A%A9.exe)
   * 原理：基于 [`libs/portable`](file:///c:/repo/RustDesk/libs/portable) 原生打包器无损内嵌官方 `PURSLANE` EV 签名的 104 个核心运行文件（`data.bin`），并在拉起内核时通过环境变量 `RUSTDESK_APPNAME` 与 `--quick_support` 参数自动注入 `chosen.sh.cn`、专属 `Key` 以及临时 `SYSTEM` 服务提权。即使客户不点击安装、或任意修改外层 `.exe` 文件名，远控端也能 100% 操控客户机上的 UAC 弹窗与管理员窗口（SAP B1 安装器、SQL Server、任务管理器等）。
2. **100% 原生 EV 数字签名中文版（零 SmartScreen 拦截 + 自动 SYSTEM 便携服务）**：
   * 路径：[`C:\repo\RustDesk\dist\上海逐城远程协助-qs-host=chosen.sh.cn,key=kjr789wzgnShiHvE0TK3P9a1jSLe1t6nG80PjhzoEXY=,.exe`](file:///c:/repo/RustDesk/dist/%E4%B8%8A%E6%B5%B7%E9%80%90%E5%9F%8E%E8%BF%9C%E7%A8%8B%E5%8D%8F%E5%8A%A9-qs-host=chosen.sh.cn,key=kjr789wzgnShiHvE0TK3P9a1jSLe1t6nG80PjhzoEXY=,.exe)
   * 原理：一字节不改官方 `.exe` 二进制，完整保留 `CN=PURSLANE (Sectigo Public Code Signing CA EV R36)` 全球扩展验证数字签名；文件名内置 `-qs-` 触发 [`is_quick_support_exe`](file:///c:/repo/RustDesk/libs/portable/src/main.rs#L375-L379) 自动拉起 `--portable-service`，并利用 [`get_custom_server_from_string`](file:///c:/repo/RustDesk/src/custom_server.rs#L64-L66) 自动从 `host=` 偏移位解析配置。

### B. 服务端迁移部署与客户端版本同步脚本
* **服务端一键部署与迁移脚本**：[`C:\repo\RustDesk\dist\deploy_rustdesk_server.ps1`](file:///c:/repo/RustDesk/dist/deploy_rustdesk_server.ps1)（同时已备份至云服务器 `C:\RustDeskServer\deploy_rustdesk_server.ps1`）。支持未来更换云服务器时一键恢复 `id_ed25519` 密钥对、拉取指定版本 `hbbs`/`hbbr`、放行防火墙、修复同机 `hosts` 内网 IP 映射并注册 `SYSTEM` 级开机守护任务。
* **客户端一键版本同步与构建脚本**：[`C:\repo\RustDesk\dist\sync_and_build_client.ps1`](file:///c:/repo/RustDesk/dist/sync_and_build_client.ps1)。未来上游发布新版时，一行命令即可自动下载新版官方包并重新编译输出 `上海逐城远程协助.exe`。

---

## 3. 历史业务暗坑与运维控制点 (Critical Pitfalls & Controls)

1. **客户 Windows Server 关闭 `mstsc` (RDP) 后画面黑屏或停止刷新**：
   * **根因**：Windows RDP 会话直接点击右上角 `X` 断开后，会话转入无图形渲染器的 `Disconnected` 状态，DXGI/GDI 无法抓取桌面帧。
   * **解法 A（推荐）**：通过 RustDesk 内置的 **TCP 隧道（端口转发）** 将远端服务器的 `3389` 端口映射到本地 `127.0.0.1:13389`，直接使用本地原生 `mstsc` 连接，支持多会话后台独立操作且不与客户抢夺鼠标。
   * **解法 B**：在客户服务器上使用 `tscon` 将会话切回 `console` 控制台，或在 RustDesk 设置中启用虚拟显示器。
2. **源码定制编译防回退准则**：
   * 若需在源码层硬编码服务器地址与公钥（免除长文件名），仅需配置 `RENDEZVOUS_SERVERS` 与 `RS_PUB_KEY` 环境变量或修改对应配置常量，遵循最小侵入原则，严禁破坏上游核心模块。
3. **云服务器同机部署被控端时的 Hairpin NAT 与 `hosts` 回环陷阱**：
   * **根因**：华为云 VPC 不支持公网 EIP (`121.37.210.146`) 本机回环（Hairpin NAT），若将 ECS 的 `C:\Windows\System32\drivers\etc\hosts` 指向 `127.0.0.1 chosen.sh.cn`，会导致 ECS 上的被控端将 `local-ip-addr` 绑定为 `127.0.0.1`，在向 `hbbr` 建立中继连接时触发 `os error 10053 (WSAECONNABORTED)`。
   * **解法**：必须在 ECS 的 `hosts` 中将 `chosen.sh.cn` 指向 ECS 真实的 VPC 内网网卡 IP（`192.168.0.72 chosen.sh.cn`），确保被控端 Socket 绑定在真实内网网卡上。
4. **控制端开启 `v2rayN` (`xray_tun`) 虚拟网卡导致直连 TCP 打洞假阳性（`deadline has elapsed`）**：
   * **根因**：当 `hbbs` 未开启强制中继时，会将被控端内网地址（如 `192.168.0.72:51706`）下发给控制端尝试 TCP 打洞。控制端 `xray_tun` 的用户态 TCP/IP 协议栈会在 `<1ms` 内伪造完成 TCP 三次握手（返回 `SYN-ACK`），导致 [`Client::connect`](file:///c:/repo/RustDesk/src/client.rs#L1538-L1552) 误判 TCP 直连成功而跳过 Relay 中继回退，最终在 [`secure_connection`](file:///c:/repo/RustDesk/src/client.rs#L1702) 死等 18 秒报 `deadline has elapsed`。
   * **解法**：在服务端 `hbbs` 启动脚本（`C:\RustDeskServer\run_hbbs.cmd`）与 `.env` 中启用 `ALWAYS_USE_RELAY=Y`，令 `hbbs` 直接下发 `RelayResponse` 走 `chosen.sh.cn:21117` 中继配对（实测端到端中继建立仅需 `11ms`），彻底绕开虚拟网卡对私有网段 IP 的假握手拦截。
5. **开源版 `rustdesk-server` 残留 `access_token` 导致 `Failed to secure tcp: deadline has elapsed`**：
   * **根因**：若客户端 `RustDesk_local.toml` 残留了旧版 API 登录的 `access_token`，会导致客户端在向开源版 `hbbs` 请求时走 [`legacy_secure`](file:///c:/repo/RustDesk/src/common.rs#L533) 明文密钥协商，而开源版 `hbbs` 仅支持带签名公钥的 `key_exchange`，从而超时 18 秒报错。
   * **解法**：使用开源版 `hbbs`（无 `api-server`）时，保持 `RustDesk2.toml` 中 `api-server = ''` 且清空 `RustDesk_local.toml` 中的 `access_token`。
