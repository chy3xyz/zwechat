// SPDX-License-Identifier: Apache-2.0
//! util — 通用工具集
//!
//! 对应 `_ref/wechat/util/`：HTTP、加解密、签名、参数排序、时间等。
//! 当前为占位骨架。

const std = @import("std");

pub const http = @import("http.zig");
pub const crypto = @import("crypto.zig");
pub const signature = @import("signature.zig");
pub const time = @import("time.zig");
pub const param = @import("param.zig");
pub const util = @import("util.zig");
pub const error_mod = @import("error.zig");
pub const rsa = @import("rsa.zig");
pub const mtls = @import("mtls.zig");
pub const asn1 = @import("asn1.zig");
pub const pkcs12 = @import("pkcs12.zig");
pub const xml = @import("xml.zig");
pub const template = @import("template.zig");
pub const sync = @import("sync.zig");
pub const retry = @import("retry.zig");
pub const uri = @import("uri.zig");
pub const json = @import("json.zig");

test "util 模块全部导出" {
    try std.testing.expect(@hasDecl(http, "getDefaultClient"));
    try std.testing.expect(@hasDecl(http, "deinitDefaultClient"));
    try std.testing.expect(@hasDecl(crypto, "calculateSign"));
    try std.testing.expect(@hasDecl(signature, "signature"));
    try std.testing.expect(@hasDecl(time, "getCurrTS"));
    try std.testing.expect(@hasDecl(param, "orderParam"));
    try std.testing.expect(@hasDecl(rsa, "parseP12"));
    try std.testing.expect(@hasDecl(mtls, "postXML"));
    try std.testing.expect(@hasDecl(mtls, "parseHttpsUri"));
    try std.testing.expect(@hasDecl(asn1, "Reader"));
    try std.testing.expect(@hasDecl(asn1, "Tag"));
    try std.testing.expect(@hasDecl(pkcs12, "parse"));
    try std.testing.expect(@hasDecl(xml, "parse"));
    try std.testing.expect(@hasDecl(template, "buildTemplateData"));
    try std.testing.expect(@hasDecl(sync, "SpinMutex"));
    try std.testing.expect(@hasDecl(retry, "callApi"));
    try std.testing.expect(@hasDecl(uri, "queryEscape"));
    try std.testing.expect(@hasDecl(json, "appendEscapedString"));
    try std.testing.expect(@hasDecl(json, "stringFieldObject"));
}
