//! util — 通用工具集
//!
//! 对应 `_ref/wechat/util/`：HTTP、加解密、签名、参数排序、时间等。
//! 当前为占位骨架。

pub const http = @import("http.zig");
pub const crypto = @import("crypto.zig");
pub const signature = @import("signature.zig");
pub const time = @import("time.zig");
pub const param = @import("param.zig");
pub const util = @import("util.zig");
pub const error_mod = @import("error.zig");
pub const rsa = @import("rsa.zig");
pub const xml = @import("xml.zig");

test "util 模块全部导出" {
    _ = http;
    _ = crypto;
    _ = signature;
    _ = time;
    _ = param;
    _ = util;
    _ = error_mod;
    _ = rsa;
    _ = xml;
}