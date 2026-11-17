# ScreenPeers · 屏伴

原生 macOS 菜单栏 VNC 连接助手，可选 DNS 动态更新。macOS 13+。

## 功能

- 菜单栏显示 VNC 来源数量，查看来源 IP、添加设备备注。
- 一键复制本机 `IP:端口` 和 `域名:端口`。
- 支持腾讯云 DNSPod、阿里云 DNS 和自定义可执行适配器。
- 默认跟随系统主网络的 IPv4；无法确定时按以太网 / Wi-Fi 备用顺序选择。
- 网络变化后更新 DNS，启动、唤醒及每小时核对，失败自动退避重试。
- 密钥保存在 macOS 钥匙串，通过标准输入传给短时运行的 Python 进程，不放入命令行参数。
- 支持登录时启动；退出 App 或 Mac 睡眠时暂停更新。

## 安装 v0.1.0 预览版

从仓库 Releases 下载 `ScreenPeers-v0.1.0-macos-arm64.zip`，解压后将 ScreenPeers.app 拖入 Applications，再打开。预编译包仅适用于 Apple Silicon；Intel Mac 可尝试从源码构建，尚未实机验证。

此版本使用 ad-hoc 签名，尚未使用 Developer ID 签名或 Apple 公证。macOS 可能阻止打开；确认来源后可在系统设置的“隐私与安全性”中允许，或从源码构建。无需关闭系统安全功能。

VNC 监控不依赖 Python。DNS 功能需要 Python 3.9+，运行时未随包附带；App 从 `/usr/bin/python3`、`/opt/homebrew/bin/python3`、`/usr/local/bin/python3` 查找解释器。构建源码还需要 Xcode Command Line Tools。

首次使用 DNS：先在服务商建立 A 记录，在 App 设置填写服务商、域名、主机记录及密钥，点击“测试并保存”，再开启自动更新。测试只查询记录；更新绑定的记录后会读回确认。详细步骤见 [域名接入指南](Docs/DNS-SETUP.md) 和 [模拟适配器](Examples/mock-dns-adapter.py)。

## 构建和测试

```sh
bash script/build_and_run.sh --build-only
PYTHONPATH=Resources python3 -B -m unittest discover -s Tests -v
swiftc -module-cache-path dist/module-cache Sources/NetworkState.swift Tests/NetworkTests.swift -o dist/network-tests
codesign --force --sign - dist/network-tests
dist/network-tests
clang Tests/test_connections.c -o dist/connection-tests
codesign --force --sign - dist/connection-tests
dist/connection-tests
```

产物为 `dist/ScreenPeers.app`，针对当前 Mac 架构构建。使用 AppKit、Swift、C 和 Python 标准库，无第三方运行时依赖包。原生测试保留断言，不使用关闭断言的优化选项。

## 数据和范围

- 配置：`~/Library/Application Support/ScreenPeers/dns.json`；密钥保存在钥匙串，JSON 保存引用。
- 设备备注和偏好保存在本机 UserDefaults；运行状态保存在本机缓存目录。仓库与发行包不包含这些数据。
- 来源数按不同 IP 去重，只计本地 TCP 5900 的 ESTABLISHED 连接；Apple 高性能屏幕共享模式尚未完整覆盖。
- DNS 发布本机 IPv4（可能为内网或 VPN 地址），不查询公网出口地址，不更新 AAAA。请确认目标 DNS 记录的可见范围适合该地址。
- 自定义适配器以当前用户权限执行，应由用户自行审查；只从可信来源选择。
- 阿里云使用模拟 API 测试；真实账户、物理换网、长期运行和其他 macOS 版本仍需进一步验证。

## 旧安装兼容

已保存的旧 tccli 账户仍可使用。源码中的 `Resources/agent.py` 和 `Resources/ddns.py` 是旧版兼容工具，不打包进 App；旧 helper 必须通过 `SCREENPEERS_LEGACY_JOB_LABEL` 指定原后台标识，缺少时拒绝同步。迁移前应先停止旧 DNS 写入任务。

如需导入旧设备备注，可在首次启动前设置 `com.screenpeers.app` 偏好中的 `legacyNotesSuite` 为原应用的偏好域。机器专用安装和回退脚本不随仓库发布。

## 许可证

当前尚未指定开源许可证，暂不授予使用、修改或分发授权。许可证确定后会在仓库更新。
