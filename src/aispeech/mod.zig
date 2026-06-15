//! aispeech — 智能对话（骨架）
//!
//! 对应 `_ref/wechat/aispeech/`：上游 Go 侧目前只有 README（"智能对话"页的
//! 占位说明），没有任何业务实现。本 Zig 版以"未来扩展位"的形式落地一个
//! 最小骨架 `AiSpeech` struct + 工厂 `init`，方便上层 `Wechat.getAiSpeech()`
//! 在后续 pass 接入时直接对齐（与 `cache.Memory` 的 `create` 风格保持一致：
//! 调用方在堆上持有，调用方负责销毁）。
//!
//! 参考上游文档：<https://developers.weixin.qq.com/doc/aispeech/platform/INTERFACEDOCUMENT.html>
//! 当前阶段 `_placeholder` 字段仅用于"非零大小 struct"——这样即使 AISpeech
//! 没有任何业务字段，也能保证 `aispeech.AiSpeech{}` 在 Zig 元组上下文中
//! 与未来的"有字段"版本保持 ABI 兼容。

const std = @import("std");

/// 智能对话业务入口（骨架）。
///
/// 当前阶段不持有任何配置 / 缓存 / 上下文；预留 `_placeholder` 字段
/// 确保 struct 至少有 1 字节大小，便于与后续扩展字段共存。
pub const AiSpeech = struct {
    /// 占位字段，确保 struct 非零大小。
    _placeholder: u8 = 0,

    const Self = @This();

    /// 构造一个空的 `AiSpeech` 实例。
    ///
    /// 当前阶段不接 allocator——后续 pass 在引入 `Config` / `Context` 之后
    /// 把签名扩展为 `pub fn init(allocator: std.mem.Allocator, cfg: Config) Self`。
    pub fn init() Self {
        return .{ ._placeholder = 0 };
    }
};

test "AiSpeech.init 返回占位实例" {
    const as_val = AiSpeech.init();
    try std.testing.expectEqual(@as(u8, 0), as_val._placeholder);
}

test "AiSpeech 默认字段值" {
    const as_val = AiSpeech{};
    try std.testing.expectEqual(@as(u8, 0), as_val._placeholder);
}

test "AiSpeech struct 至少 1 字节" {
    try std.testing.expect(@sizeOf(AiSpeech) >= 1);
}
