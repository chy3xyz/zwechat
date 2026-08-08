# httpz — 上游来源与许可证声明

本目录是 **zwechat** 项目 vendored 的第三方依赖，用于微信支付 mTLS 双向认证
（`util/http.zig` 的 `postXMLWithTLS`）。

## 上游来源

- 项目：httpz.zig
- 仓库：<https://github.com/allain/httpz.zig>
- 安装方式（上游 README）：`zig fetch --save git+https://github.com/allain/httpz.zig`
- 本仓库 vendored 版本：v0.2.0（`vendor/httpz/build.zig.zon` 中 `.version = "0.2.0"`）

## 许可证状态

上游仓库（截至 vendoring 时）**未提供 LICENSE 文件**（GitHub API 显示 `license: null`，
仓库根目录无 LICENSE / COPYING 文件）。因此本目录不附带任何许可证文本，也不对此
代码的授权状态做任何声明。使用者应自行向上游确认授权条款。

## 本地修改

zwechat 在 vendoring 时对上游打了本地补丁：

- `vendor/httpz/src/openssl.zig`：在 `config.Client` 中新增可选 `cert: ?*const CertKeyPair`，
  握手时调用 `SSL_CTX_use_certificate_PEM` / `SSL_CTX_use_PrivateKey_PEM` 加载客户端
  证书，以支持微信支付要求的 mTLS 双向认证。

补丁内容可在 `git log -- vendor/httpz` 中追溯。
