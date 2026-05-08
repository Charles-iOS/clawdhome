---
name: openclaw 和 Node.js 二进制位置
description: openclaw 和 node 打包在 app bundle 内，不在用户的 .npm-global 中；findOpenclawBinary 仅对 Shrimp 用户有效
type: project
originSessionId: 764820c4-4a49-41ff-8cac-efd151569539
---
openclaw 二进制和 Node.js 运行时都打包在 EZRWorker.app bundle 内（Resources 或 dev-runtime），**不是**通过 npm install 安装到用户的 `~/.npm-global/bin/` 的。

`ConfigWriter.findOpenclawBinary(for:)` 查找的是 `~<username>/.npm-global/bin/openclaw`，这只对 Shrimp 用户（由 app 创建的受管用户）有效，因为 Shrimp 用户的 openclaw 是通过 `InstallManager` 安装到其 `~/.npm-global/` 中的。

**Why:** 当前登录用户（管理员，如 charles）的 `~/.npm-global/bin/openclaw` 通常不存在，因为 openclaw 是 app 为 Shrimp 用户安装的。直接用 `NSUserName()` 作为 username 调 `runPairingCommand` 会导致 `findOpenclawBinary` 失败 → "参数解析失败"。

**How to apply:** 凡是需要调用 `runPairingCommand` / `runOpenclawCommand` 等 helper 命令的地方，username 必须传 Shrimp 用户名，不能传当前管理员用户名（`NSUserName()`）。在 app 的主窗口上下文中需要找到正确的 Shrimp username。
