# httpz — 上游来源与许可证声明

`httpz` 是 **zwechat** 的第三方 Zig 依赖，通过 `build.zig.zon` 以 URL 方式引入，
用于微信支付 mTLS 双向认证（`util/http.zig` 的 `postXMLWithTLS`）。

## 上游来源

- 项目：zhttp（原 httpz.zig 的延续仓库）
- 仓库：<https://github.com/chy3xyz/zhttp>
- 上游原始项目：<https://github.com/allain/httpz.zig>
- 引入方式：`build.zig.zon` `.httpz` 依赖 → `git+https://github.com/chy3xyz/zhttp?ref=v0.6.1#60a02128e28e0f43211d831e5bc4a2b4c2c08dc6`（由 `zig fetch` 下载，hash 校验）
- 版本：v0.6.1

## 许可证状态

上游仓库（截至引入时）**未提供 LICENSE 文件**（仓库根目录无 LICENSE / COPYING 文件）。
因此本依赖不附带任何许可证文本，也不对其代码的授权状态做任何声明。使用者应自行
向上游确认授权条款。

## 本地修改

**无。** 本项目不再对上游打本地补丁：

- mTLS 客户端证书支持（`tls.config.Client.auth` / `cert` 字段）已由上游 v0.6.0 官方实现
  （提交 `0431984 feat(tls): add mTLS client certificate & key support (auth/cert) for Client`），v0.6.1 延续。
- OpenSSL include 路径由上游 `-Dopenssl-include` 构建选项参数化（提交 `46dad65`），
  跨平台路径由 zwechat `build.zig` 的 `setupOpenSSL` 探测并透传。
