# 第三方依赖与许可证声明

## 当前状态：无第三方 Zig 依赖

自本版本（`CHANGELOG.md` 的 `[Unreleased]`）起，`build.zig.zon` 的 `.dependencies`
为空——**zwechat 不引入任何第三方 Zig 包**，也不再分发任何第三方 Zig 源码。

微信支付 v2 所需的 mTLS（客户端证书）改为仓库内自建：`src/util/mtls.zig` +
`src/util/mtls_openssl.zig`，在运行时用 `std.DynLib` 加载系统的 OpenSSL
（`libssl` / `libcrypto`），通过手写 `extern` 函数指针调用，**不需要头文件、不参与链接**。

- 默认构建（`-Dmtls=false`）：不接触 OpenSSL，零 C 依赖。
- `-Dmtls=true`：仍不与 OpenSSL 链接，只在运行到 mTLS 路径时 `dlopen` 动态库；
  该动态库由使用方自行安装，本项目不分发。
- 使用的 OpenSSL 函数均为 1.1.0 起的稳定 ABI；OpenSSL 3.x 采用 Apache-2.0 许可。

## 历史记录：zhttp（已移除）

0.1.x – 0.4.5 期间，本项目曾通过 `build.zig.zon` 引入第三方依赖 `zhttp`
（`httpz.zig` 的延续仓库），用于 `util/http.zig` 的 `postXMLWithTLS`（微信支付 mTLS）：

- 项目：zhttp（原 httpz.zig 的延续仓库）
- 仓库：<https://github.com/chy3xyz/zhttp>
- 上游原始项目：<https://github.com/allain/httpz.zig>
- 曾用版本：v0.6.1（`git+https://github.com/chy3xyz/zhttp?ref=v0.6.1#60a02128e28e0f43211d831e5bc4a2b4c2c08dc6`）
- 移除原因：它把 OpenSSL + libc 链接到了**所有**构建目标（lib / exe / test / bench /
  examples），使每个消费者都背 C 依赖，而收益仅覆盖微信支付 v2 的 mTLS 这一条窄路径；
  此外上游仓库**未提供 LICENSE 文件**（引入时根目录无 LICENSE / COPYING），
  移除后不再存在该项授权不确定性。参见 `docs/OPEN_ITEMS.md` 的零依赖取舍条目。

移除后，微信支付 **v3** 的退款 / 转账（`src/pay/v3/refund.zig`、`src/pay/v3/transfer.zig`）
不需要客户端证书，可直接替代 v2 对应能力；仅 v2 现金红包仍需要 mTLS（需显式 `-Dmtls=true`）。
