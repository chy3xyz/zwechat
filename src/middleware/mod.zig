// SPDX-License-Identifier: Apache-2.0
//! middleware —zwechat 中间件模块（适配 zfinal / zigmodu 及通用 HTTP 框架）

const std = @import("std");

pub const handler = @import("wechat_handler.zig");
pub const verifyServerSignature = handler.verifyServerSignature;
pub const handleServerMessage = handler.handleServerMessage;
pub const CallbackQuery = handler.CallbackQuery;
pub const DecryptedMessage = handler.DecryptedMessage;

test "middleware 模块导出" {
    try std.testing.expect(@hasDecl(handler, "verifyServerSignature"));
    try std.testing.expect(@hasDecl(handler, "handleServerMessage"));
    try std.testing.expect(@hasField(CallbackQuery, "signature"));
    try std.testing.expect(@hasField(CallbackQuery, "timestamp"));
    try std.testing.expect(@hasField(DecryptedMessage, "raw_xml"));
    try std.testing.expect(@hasDecl(DecryptedMessage, "deinit"));
}
