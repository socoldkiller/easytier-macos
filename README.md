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
    <img alt="macOS" src="https://img.shields.io/badge/macOS-14%2B-111111?style=for-the-badge&logo=apple&logoColor=white" />
    <img alt="Swift" src="https://img.shields.io/badge/Swift-Native-F05138?style=for-the-badge&logo=swift&logoColor=white" />
    <a href="https://github.com/socoldkiller/easytier-swift/stargazers">
      <img alt="Stars" src="https://img.shields.io/github/stars/socoldkiller/easytier-swift?style=for-the-badge&logo=github&label=Stars" />
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

### App 模式

- **Normal**：本机启动 EasyTier 实例，自建网络
- **Remote**：连到另一台设备的 RPC Portal，远程管理它的网络
- **Config Server**：从远端同步配置，统一管理多台设备

### 特权 Helper

TUN 网卡需要 root 权限。App 会引导你安装一个 privileged helper（LaunchDaemon），只在网络启动时用到。非 TUN 模式（`no_tun`）不需要。

## 安装

macOS 14 及以上。

去 [Releases](https://github.com/socoldkiller/easytier-swift/releases) 下载最新 DMG，拖进 Applications。

首次启动：
1. macOS 可能提示「无法验证开发者」，去系统设置 → 隐私与安全性 → 仍要打开
2. 启动后会提示安装 Helper，按 macOS 弹窗操作
3. 如果开了防火墙，允许 EasyTier 的入站连接

## 构建

需要 Xcode 16+（带 Swift 6）、Rust 工具链（nightly）。

```bash
git clone --recurse-submodules https://github.com/socoldkiller/easytier-swift.git
cd easytier-swift

# 编译 Rust FFI 静态库
make build-ffi

# 编译 Swift App
make build

# 打包 DMG
make dmg

# 跑测试
swift test
cd Rust/EasyTierGuiFFI && cargo test
```

产物路径：
- App bundle：`.build/debug/EasyTierMac.app`
- FFI 库：`Rust/EasyTierGuiFFI/target/`
- DMG：`easytier-mac.dmg`

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
  <a href="https://www.star-history.com/#socoldkiller/easytier-swift&Date">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=socoldkiller/easytier-swift&type=Date&theme=dark" />
      <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=socoldkiller/easytier-swift&type=Date" />
      <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=socoldkiller/easytier-swift&type=Date" />
    </picture>
  </a>
</div>

## 致谢

基于 [EasyTier](https://github.com/EasyTier/EasyTier) 的组网能力，用 SwiftUI + Rust FFI 做了 Mac 原生体验。

Bug 和功能建议提 Issue，想帮忙改直接 PR。觉得还行的话点个 Star。

## License

MIT。EasyTier Core 及其依赖遵循各自的许可证。
