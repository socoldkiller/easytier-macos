<div align="center">
  <br />
  <img src="Sources/EasyTierMac/Resources/easytier-icon.png" width="108" alt="EasyTier icon" />

  <h1>EasyTier for macOS</h1>

  <p>
    EasyTier 的 Mac 原生桌面客户端。在一个窗口里管理组网、看状态、查流量。
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
</div>

---

## 截图

<div align="center">
  <img src="pictures/status-overview.png" width="920" alt="status overview" />
  <br /><br />
  <img src="pictures/config-editor.png" width="420" alt="config" />
  &nbsp;
  <img src="pictures/traffic-view.png" width="420" alt="traffic" />
  <br /><br />
  <img src="pictures/menu-bar-panel.png" width="420" alt="menu bar" />
  &nbsp;
  <img src="pictures/mode-settings.png" width="420" alt="settings" />
</div>

## 做了什么

- **菜单栏常驻**：不用开窗口就能看到连接状态，点开面板快速切换网络。
- **设备列表**：当前网络里有哪些设备、走什么路线、延迟多少、NAT 类型，一目了然。
- **流量图表**：上传下载趋势直接画出来，不用猜网络有没有在跑。
- **多网络切换**：家里、公司、服务器分开保存，点一下就能切。
- **运行日志**：出问题时翻一下，起码知道从哪里开始排查。
- **TOML 导入导出**：和命令行配置互通的，不用重新填。

## 安装

macOS 14 以上。

去 [Releases](https://github.com/socoldkiller/easytier-swift/releases) 下最新 DMG，拖进 Applications 就行。首次启动会提示安装 Helper 和网络权限，照 macOS 弹窗点允许就好。

## 构建

```bash
git clone --recurse-submodules https://github.com/socoldkiller/easytier-swift.git
cd easytier-swift
make build-ffi     # 先编 Rust FFI
make build         # 再编 Swift
```

FFI 产物会放在 `Rust/EasyTierGuiFFI/target/`，Swift 这边通过 `CEasyTierFFI` 模块桥接调用。

## 致谢

基于 [EasyTier](https://github.com/EasyTier/EasyTier)，用 SwiftUI + Rust FFI 包的皮。

有问题提 Issue，想帮忙改直接 PR。Star 也欢迎。

## License

MIT
