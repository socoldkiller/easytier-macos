<div align="center">
  <br />
  <img src="Sources/EasyTierMac/Resources/easytier-icon.png" width="108" alt="EasyTier icon" />

  <h1>EasyTier for macOS</h1>

  <p>
    EasyTier 的 Mac 原生桌面客户端。用 SwiftUI 写的，底层通过 Rust FFI 调用 EasyTier Core。
  </p>
  <p>
    家里 NAS、公司电脑、云服务器，放在同一个虚拟局域网里。不用背命令，打开 App 就能看到连上了没、谁在线、网速怎么样。
  </p>

  <p>
    <img alt="macOS" src="https://img.shields.io/badge/macOS-15%2B-111111?style=for-the-badge&logo=apple&logoColor=white" />
    <img alt="Swift" src="https://img.shields.io/badge/Swift-Native-F05138?style=for-the-badge&logo=swift&logoColor=white" />
    <a href="https://github.com/socoldkiller/easytier-macos/stargazers">
      <img alt="Stars" src="https://img.shields.io/github/stars/socoldkiller/easytier-macos?style=for-the-badge&logo=github&label=Stars" />
    </a>
    <a href="LICENSE">
      <img alt="License" src="https://img.shields.io/badge/License-MIT-34D399?style=for-the-badge" />
    </a>
  </p>

  <p>
    <a href="#截图">截图</a>
    ·
    <a href="#功能">功能</a>
    ·
    <a href="#安装">安装</a>
    ·
    <a href="#构建">构建</a>
    ·
    <a href="#架构">架构</a>
    ·
    <a href="#star-历史">Star 历史</a>
    ·
    <a href="#致谢">致谢</a>
  </p>

  <br />
</div>

---

## 截图

应用的主界面 —— 左栏切网络，右栏看状态、设备、流量、日志。

<div align="center">
  <img src="pictures/status-overview.png" width="920" alt="Status overview" />

  <br /><br />

  <img src="pictures/config-editor.png" width="420" alt="Config editor" />
  &nbsp;
  <img src="pictures/traffic-view.png" width="420" alt="Traffic view" />

  <br /><br />

  <img src="pictures/menu-bar-panel.png" width="420" alt="Menu bar panel" />
  &nbsp;
  <img src="pictures/mode-settings.png" width="420" alt="Mode settings" />

  <br /><br />

  <img src="pictures/runtime-logs.png" width="420" alt="Runtime logs" />
</div>

## 功能

### 菜单栏常驻

菜单栏图标会实时反映连接状态 —— 灰色是停的，闪烁是正在连，绿色是全通，红色是出错了。点一下弹出面板，不用切到主窗口就能看到当前网络和在线设备。

### 设备列表

一张表列清当前网络里所有节点。每行显示：
- 设备名和 IP（点一下就能复制）
- 路线类型（P2P、Relay、Local）
- 隧道协议（TCP、UDP、QUIC 等）
- 延迟、上传量、下载量、丢包率
- NAT 类型和 EasyTier 版本

设备名可以直接双击改名，改完通过 RPC 实时生效到远端。

### 流量图表

上传和下载趋势画成面积图。鼠标悬停看具体数值，每秒自动刷新。图表自动调整 Y 轴刻度，不会因为偶尔的流量尖峰把曲线压扁。

### 多网络配置

每个网络独立保存成 TOML 文件，开关互不影响。可以用 Cmd+[ / Cmd+] 在配置之间快速切换。支持导入导出 TOML，和命令行配置格式互通。

### 运行日志

EasyTier Core 的运行输出和 App 自身的操作记录都收在一个日志面板里。可以复制、搜索，出问题时起码知道从哪看起。

### 远程管理

在设备表里双击任意远端节点可改其主机名，改名通过 RPC 实时同步到对端。

### 特权 Helper

TUN 网卡需要 root 权限。App 会引导你安装一个 privileged helper（LaunchDaemon），只在网络启动时用到。非 TUN 模式（`no_tun`）不需要。

## 安装

macOS 15 及以上。

去 [Releases](https://github.com/socoldkiller/easytier-macos/releases) 下载最新 DMG，拖进 Applications。

从 v1.4.0 开始，后续版本可通过 `EasyTier > Check for Updates…` 直接验证、安装并重新启动，不再需要打开 Finder 或拖拽 DMG。由于 v1.3.3 及更早版本尚未内置 Sparkle，升级到 v1.4.0 仍需完成最后一次手动安装。

首次启动：
1. Release DMG 已经过 Developer ID 签名和 Apple 公证；如果 macOS 提示无法验证开发者，请不要绕过 Gatekeeper，重新下载并提交 Issue
2. 启动后会提示安装 Helper，按 macOS 弹窗操作
3. 如果开了防火墙，允许 EasyTier 的入站连接

## 构建

需要 Xcode 16+（带 Swift 6）、Rust 1.95+ stable 工具链和 Protocol Buffers 编译器（`protoc`）。运行测试不需要签名证书；打包 App 需要 Developer ID Application 证书、匹配的 provisioning profile 和 Sparkle 公钥，最终 DMG 还需要有效的 `notarytool` profile。

```bash
git clone --recurse-submodules https://github.com/socoldkiller/easytier-macos.git
cd easytier-macos

make bootstrap   # 检查工具链
make ffi         # 编译当前 Mac 架构的 Rust FFI 静态库
make test        # 运行 Swift 和 Rust 测试
```

产物路径：
- App bundle：`.build/artifacts/EasyTier.app`
- FFI 库：`Vendor/Frameworks/static/libeasytier_ffi.a`
- DMG：`.build/artifacts/EasyTier-macOS-ARM64.dmg`

Developer ID 打包：

```bash
export CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)"
export PROVISIONING_PROFILE="/path/to/EasyTier.provisionprofile"
export SPARKLE_PUBLIC_ED_KEY="base64-public-key-from-generate_keys"
make app-debug \
  CODESIGN_IDENTITY="$CODESIGN_IDENTITY" \
  PROVISIONING_PROFILE="$PROVISIONING_PROFILE" \
  SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY"

# 在版本 tag 上运行时会得到稳定版本号和 build number；未打 tag 时显式传 APP_VERSION。
make dmg \
  CODESIGN_IDENTITY="$CODESIGN_IDENTITY" \
  PROVISIONING_PROFILE="$PROVISIONING_PROFILE" \
  SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
  APP_VERSION=1.4.0
```

`make dmg` 现在只生成最终发布产物：App 先公证并 staple，再创建 DMG，之后 DMG 再公证、staple，并通过 quarantine/Gatekeeper 全链路验证，不再暴露“只有签名但尚未公证”的 DMG 入口。Provisioning profile 必须授权应用自己的 Keychain access group，用于 Data Protection Keychain；不要把 profile 提交到仓库。缺少正确签名配置时会直接失败，不会生成降级包。

完整的本地与 CI 发布配置见 [`Packaging/RELEASE.md`](Packaging/RELEASE.md)，Sparkle 生产密钥设置见 [`Packaging/SPARKLE.md`](Packaging/SPARKLE.md)。

## 架构

```
┌────────────────────────────────┐
│  SwiftUI App (EasyTierMac)     │
│  Views / Menu Bar / Settings   │
├────────────────────────────────┤
│  EasyTierShared (Models / RPC) │
├──────────────┬─────────────────┤
│  Privileged  │  Static FFI     │
│  Helper (XPC)│  Client (C ABI) │
├──────────────┴─────────────────┤
│  CEasyTierFFI (C shim)         │
├────────────────────────────────┤
│  Rust FFI (EasyTierGuiFFI)     │
│  → easytier Core               │
└────────────────────────────────┘
```

两块路径到达 EasyTier Core：
1. **本机直调**：Swift → C shim → Rust FFI → EasyTier Core（StaticEasyTierFFIClient）
2. **特权 Helper**：Swift → XPC → privileged helper daemon → Rust FFI → EasyTier Core（用于 TUN）

RPC 远程调用也走 FFI：Swift 构造 JSON-RPC payload → C shim → Rust 发起 TCP 连接到远端 RPC Portal。

## Star 历史

<div align="center">
  <a href="https://www.star-history.com/#socoldkiller/easytier-macos&Date">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=socoldkiller/easytier-macos&type=Date&theme=dark" />
      <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=socoldkiller/easytier-macos&type=Date" />
      <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=socoldkiller/easytier-macos&type=Date" />
    </picture>
  </a>
</div>

## 致谢

基于 [EasyTier](https://github.com/EasyTier/EasyTier) 的组网能力，用 SwiftUI + Rust FFI 做了 Mac 原生体验。

Bug 和功能建议提 Issue，想帮忙改直接 PR。觉得还行的话点个 Star。

## License

MIT。EasyTier Core 及其依赖遵循各自的许可证。
