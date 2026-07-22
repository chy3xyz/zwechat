//! middleware —zwechat 中间件模块（适配 zfinal / zigmodu 及通用 HTTP 框架）

const std = @import("std");

pub const handler = @import("wechat_handler.zig");
pub const verifyServerSignature = handler.verifyServerSignature;
pub const handleServerMessage = handler.handleServerMessage;
pub const CallbackQuery = handler.CallbackQuery;
pub const DecryptedMessage = handler.DecryptedMessage;

test "middleware 模块导出" {
    _ = handler;
    _ = verifyServerSignature;
    _ = handleServerMessage;
    _ = CallbackQuery;
    _ = DecryptedMessage;
}
