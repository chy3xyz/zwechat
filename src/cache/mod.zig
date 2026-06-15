//! cache — 缓存抽象
//!
//! 对应 `_ref/wechat/cache/`：定义 `Cache` 接口与 `Memory` 实现（`Redis` / `Memcache`
//! 后续可按相同 vtable 契约补齐）。
//!
//! 设计要点：
//! - `Cache` 是值类型 + vtable 的胖指针（ctx + vtable），持有者只承担 16 字节。
//! - 具体实现（如 `Memory`）把自己 `*anyopaque` 注入 `ctx`，并提供 `*const VTable`。
//! - `Cache.deinit()` 通过 vtable 释放具体资源；调用后该句柄失效。
//! - 所有错误落到 `CacheError`，与上游 Go 版 `error` 等价。

const std = @import("std");

/// 缓存相关错误集合。
///
/// - `NotFound`     ：键不存在（`get` 之外返回值的场景下用于显式语义）。
/// - `TypeMismatch` ：值类型与请求不符（当前 `[]const u8` 协议用不到，预留给反序列化层）。
/// - `StorageError` ：底层存储失败（Redis / Memcache 等网络异常）。
/// - `OutOfMemory`  ：分配失败。
pub const CacheError = error{
    NotFound,
    TypeMismatch,
    StorageError,
    OutOfMemory,
};

/// 缓存接口的轻量句柄。值拷贝廉价，使用方应保持底层 `ctx` 存活。
///
/// 调用方通过 `Memory.asCache()` 等工厂方法获得；具体实现的释放由 `deinit`
/// 触发底层 vtable 完成。
pub const Cache = struct {
    /// 指向具体实现的指针（如 `*Memory`）。
    ctx: *anyopaque,
    /// 具体实现提供的虚表。
    vtable: *const VTable,

    pub const VTable = struct {
        get: *const fn (ctx: *anyopaque, key: []const u8) CacheError!?[]const u8,
        set: *const fn (ctx: *anyopaque, key: []const u8, val: []const u8, ttl_seconds: i64) CacheError!void,
        isExist: *const fn (ctx: *anyopaque, key: []const u8) CacheError!bool,
        delete: *const fn (ctx: *anyopaque, key: []const u8) CacheError!void,
        deinit: *const fn (ctx: *anyopaque) void,
    };

    /// 获取缓存值。命中且未过期返回 `value`，未命中返回 `null`，错误返回 `CacheError!T`。
    ///
    /// 返回的切片由缓存实现持有；调用方**不应释放**。
    pub fn get(self: Cache, key: []const u8) CacheError!?[]const u8 {
        return self.vtable.get(self.ctx, key);
    }

    /// 设置缓存条目。`ttl_seconds <= 0` 表示永不过期。
    pub fn set(self: Cache, key: []const u8, val: []const u8, ttl_seconds: i64) CacheError!void {
        return self.vtable.set(self.ctx, key, val, ttl_seconds);
    }

    /// 判断键是否存在且未过期。
    pub fn isExist(self: Cache, key: []const u8) CacheError!bool {
        return self.vtable.isExist(self.ctx, key);
    }

    /// 删除键。键不存在不视为错误。
    pub fn delete(self: Cache, key: []const u8) CacheError!void {
        return self.vtable.delete(self.ctx, key);
    }

    /// 释放底层实现持有的资源。调用后本句柄失效，不可再使用。
    pub fn deinit(self: Cache) void {
        self.vtable.deinit(self.ctx);
    }
};

/// 进程内线程安全的内存缓存实现。
pub const Memory = @import("memory.zig").Memory;

/// Redis 缓存实现。
pub const Redis = @import("redis.zig").Redis;

test "Cache 接口契约自检：get / set / isExist / delete / deinit 均存在" {
    try std.testing.expect(@hasDecl(Cache, "get"));
    try std.testing.expect(@hasDecl(Cache, "set"));
    try std.testing.expect(@hasDecl(Cache, "isExist"));
    try std.testing.expect(@hasDecl(Cache, "delete"));
    try std.testing.expect(@hasDecl(Cache, "deinit"));
}

test "CacheError 错误集暴露给外部" {
    // 编译期确认变体存在（无需运行时断言）。
    const e1: CacheError = error.NotFound;
    const e2: CacheError = error.TypeMismatch;
    const e3: CacheError = error.StorageError;
    const e4: CacheError = error.OutOfMemory;
    // 仅引用以避免「未使用变量」警告。
    try std.testing.expect(e1 != e2);
    try std.testing.expect(e3 != e4);
}
