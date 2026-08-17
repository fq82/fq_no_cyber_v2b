# MediaCover v2board & Xboard 无侵入对接插件

> **透明·安全·无侵入**：本插件源码完全开源，专为消除客户疑虑设计。
> 客户保留自有 v2board / Xboard 负责用户账本、套餐、财务与支付；节点与加速网络由 MediaCover 平台提供。

---

## 🌐 官方平台与服务地址 (Official Portals)

| 平台模块 | 官方网址 | 说明 |
| :--- | :--- | :--- |
| **官方控制台 (Portal)** | **[https://kaka2.lol/](https://kaka2.lol/)** | 租户控制中心：查看节点状态、用量账单、管理多套 v2board 对接 |
| **官方授权商店 (新购/续费)** | **[https://shop.kaka2.lol/](https://shop.kaka2.lol/)** | **新购授权 / 续费充值**：支持 USDT (TRC20) 全自动即时到账，一键购码注册与续期 |

---

## 📖 官方简介 (About MediaCover)

**MediaCover** 是一套面向商用场景的高隐蔽性隧道中转与加速平台：
- **核心护城河（媒资伪装数据面）**：不同于传统的 SS/VMess/VLESS/REALITY 等具有明显流量指纹的协议，MediaCover 在客户端至国内第一跳入口之间，采用**真实 MPEG-TS 视频流容器与 JPEG 图片切片嵌入 ChaCha20-Poly1305 AEAD 加密载荷**，从物理流量形态上呈现为正常的 CDN 媒体分发流量，有效降低主动探测与特征识别命中。
- **商业多跳架构**：
  - **国内入口**：平台运营超级入口集群，对客户端屏蔽底层网络细节。
  - **加速中继**：平台内部多区域加密专线骨干链路。
  - **海外落地**：客户自带（BYO）落地服务器，平台不触碰客户出站数据，权限模型清晰独立。
  - **计费模式**：平台按实际中转流量向租户批发（元/T），租户自定套餐零售。

---

## 🌟 核心设计原则（为什么客户可以完全放心？）

1. **绝对零侵入（不改动原站任何业务代码）**：
   - 绝不修改 Laravel 内核（Kernel）、路由表（`routes/web.php`）或原有 Controller。
   - 仅在 `public/index.php` 挂载轻量前置拦截，所有原站用户登录、充值、订单、管理员后台 **100% 原样放行**。
2. **彻底封死订阅导出（保护节点网络防抓包）**：
   - 在请求到达 Laravel 前，直接对通用订阅路径（`/api/v1/client/subscribe`、Clash、Shadowrocket、Base64 订阅等）返回 404。
   - C 端用户使用专属 App 登录并直连，**永不泄露原始节点 IP 与订阅链接**。
3. **一键安装 / 一键无损卸载**：
   - 卸载时只需一条命令即可完全恢复原状，不留任何后门或残留代码。

---

## 📁 源码结构

```text
├── install.sh                  # 自动化安装与卸载脚本（自动扫描 v2board 路径）
├── README.md                   # 说明文档
├── LICENSE                     # MIT 开源许可证
└── src/
    ├── bootstrap.php           # 前置无侵入入口（路由分流与订阅拦截）
    ├── Controllers/
    │   └── CoverLandingController.php  # C 端下载引导落地页 (/cover)
    ├── Middleware/
    │   └── KillSubscribe.php           # 订阅封杀中间件
    └── Support/
        └── PlatformSettings.php        # 平台安全配置与通信支持库
```

---

## 🚀 快速安装

不要把远程脚本直接通过管道交给 root。先下载到本地、核对发布方提供的 SHA-256/签名并审阅，再执行：

```bash
curl -fL https://kaka2.lol/install/customer.sh -o customer.sh
sha256sum customer.sh
less customer.sh
sudo bash customer.sh \
  --role plugin \
  --panel https://kaka2.lol \
  --tenant 你的租户ID \
  --board-id 你的BoardID \
  --plugin-token 你的PluginToken
```

或使用本仓库源码直接离线安装：

```bash
git clone https://github.com/fq82/fq_no_cyber_v2b.git
COVER_PANEL_URL=https://kaka2.lol COVER_TENANT_ID=ten_xxx COVER_PLUGIN_TOKEN=ptk_xxx \
  bash fq_no_cyber_v2b/install.sh /www/wwwroot/你的v2board目录
```

---

## 🔍 安装验收

| 检查项 | 访问地址 | 预期表现 |
| :--- | :--- | :--- |
| **C 端引导页** | `https://你的域名/cover` | 正常展示 MediaCover 专属客户端下载与使用指引 |
| **通用订阅链接** | `https://你的域名/api/v1/client/subscribe?token=...` | **返回 404**（杜绝节点泄露） |
| **原有 v2board 后台** | `https://你的域名/admin` | **完全正常**，不受任何干扰 |

---

## 🧹 一键无损卸载

优先使用安装时保留在站点内的同版本卸载器：

```bash
bash /path/to/v2board/cover-plugin/install.sh uninstall /path/to/v2board
```

卸载器会拒绝 symlink 入口、损坏/非 regular-file 快照，以及任何“无可信原始字节快照”的有损文本回退；失败时保留 `cover-plugin/` 和快照供重试或人工恢复。

持久化设置缓存只在 `cover-plugin/storage` 由当前 PHP-FPM UID 拥有且目录权限严格为 `0700` 时启用；缓存文件必须为同一 UID 拥有的 regular file 且权限严格为 `0600`。条件不满足时不会回退到公共 `/tmp`，平台请求失败仍按 fail-closed 封锁。

---

## 📄 License
MIT License. Open source and transparent.
