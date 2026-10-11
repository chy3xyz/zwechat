// SPDX-License-Identifier: Apache-2.0
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
        /// 可选槽位：命中则返回**调用方拥有所有权**的副本（`null` = 未命中）。
        ///
        /// 实现方必须在自己内部的临界区里完成拷贝（Memory 在互斥区内、Redis /
        /// Memcache 在独占借用连接的期间内），因此返回的切片不受后续任何写操作影响。
        ///
        /// **默认值是 `null`**：既有与自定义 `Cache` 实现无需改动即可继续编译
        /// （构造 `VTable` 字面量时可以不写这个字段），`Cache.getOwned` 会退化为
        /// `get` + `dupe`（见其文档：那种退化不比现状更安全）。
        getOwned: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, key: []const u8) CacheError!?[]u8 = null,
    };

    /// 获取缓存值。命中且未过期返回 `value`，未命中返回 `null`，错误返回 `CacheError!T`。
    ///
    /// 返回的切片由缓存实现持有；调用方**不应释放**。
    ///
    /// **生命周期契约**：返回的是借用切片，有效期至该 Cache 实例的任何后续写操作
    /// （`set` / `delete` / 同一 key 覆盖写）或 `deinit`。调用方需要跨写操作持有时
    /// 必须 `allocator.dupe`。Memory 与 Memcache / Redis 后端均适用此契约：
    /// Memory 按条目存储（覆盖写才失效），Memcache / Redis 复用内部 `last_value`
    /// 缓冲区（任何后续 `get` 都会 free 并覆盖，立即悬垂）。
    pub fn get(self: Cache, key: []const u8) CacheError!?[]const u8 {
        return self.vtable.get(self.ctx, key);
    }

    /// 设置缓存条目。`ttl_seconds <= 0` 表示永不过期。
    pub fn set(self: Cache, key: []const u8, val: []const u8, ttl_seconds: i64) CacheError!void {
        return self.vtable.set(self.ctx, key, val, ttl_seconds);
    }

    /// 命中则返回**调用方拥有所有权**的副本（由 `allocator` 分配，调用方负责 `free`），
    /// 未命中返回 `null`。
    ///
    /// 与 `get` 的区别：`get` 返回的借用切片只在本实例下一次写操作之前有效，
    /// 若另一处（另一个对象 / 宿主模块）与本实例共享同一个 `Cache` 并在并发地写同一个
    /// key，先 `get` 再 `dupe` 就成了读已释放内存。本方法把这步拷贝移进**实现自己的
    /// 临界区**（Memory 的互斥区；Redis / Memcache 的独占借出连接期间），跨对象共享
    /// 同一个 Cache 时依然安全。
    ///
    /// 实现没有提供 `getOwned` 槽位（`null`，也是本接口的默认值）时退化为
    /// `get` + `dupe`：行为与调用方手写 `get` 后 `dupe` 完全等价，**不比现状更安全**，
    /// 只是把崩溃面从调用方收敛到一处。既有 / 自定义实现因此无需改动即可继续编译。
    pub fn getOwned(self: Cache, allocator: std.mem.Allocator, key: []const u8) CacheError!?[]u8 {
        if (self.vtable.getOwned) |f| return f(self.ctx, allocator, key);
        const borrowed = (try self.get(key)) orelse return null;
        return try allocator.dupe(u8, borrowed);
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

/// Memcache 缓存实现。
pub const Memcache = @import("memcache.zig").Memcache;

test "Cache 接口契约自检：get / set / isExist / delete / deinit / getOwned 均存在" {
    try std.testing.expect(@hasDecl(Cache, "get"));
    try std.testing.expect(@hasDecl(Cache, "set"));
    try std.testing.expect(@hasDecl(Cache, "isExist"));
    try std.testing.expect(@hasDecl(Cache, "delete"));
    try std.testing.expect(@hasDecl(Cache, "deinit"));
    try std.testing.expect(@hasDecl(Cache, "getOwned"));
    // `getOwned` 是**可选**槽位：存在且默认值为 null（见下面的 LegacyCache 用例）。
    try std.testing.expect(@hasField(Cache.VTable, "getOwned"));
}

/// 手写的「旧式」Cache 实现：只提供最初那 5 个槽位，**故意不写 getOwned**。
///
/// 它存在的意义是把「新增可选槽位不破坏既有实现者的编译」钉成一条测试：
/// 一旦 `VTable.getOwned` 被改成必填字段（去掉默认值），这个结构体字面量
/// 立刻编译失败，用例也就红了。同时它还验证了 `Cache.getOwned` 的退化路径
/// （`get` + `dupe`）对这类实现仍然可用。
const LegacyCache = struct {
    map: std.StringHashMapUnmanaged([]const u8) = .empty,
    allocator: std.mem.Allocator,

    fn asCache(self: *LegacyCache) Cache {
        return .{ .ctx = @ptrCast(self), .vtable = &legacy_vtable };
    }

    const legacy_vtable: Cache.VTable = .{
        .get = legacyGet,
        .set = legacySet,
        .isExist = legacyIsExist,
        .delete = legacyDelete,
        .deinit = legacyDeinit,
    };

    fn legacyGet(ctx: *anyopaque, key: []const u8) CacheError!?[]const u8 {
        const self: *LegacyCache = @ptrCast(@alignCast(ctx));
        return self.map.get(key);
    }

    fn legacySet(ctx: *anyopaque, key: []const u8, val: []const u8, ttl_seconds: i64) CacheError!void {
        _ = ttl_seconds;
        const self: *LegacyCache = @ptrCast(@alignCast(ctx));
        if (self.map.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
        const owned_key = self.allocator.dupe(u8, key) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned_key);
        const owned_val = self.allocator.dupe(u8, val) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned_val);
        self.map.put(self.allocator, owned_key, owned_val) catch return error.OutOfMemory;
    }

    fn legacyIsExist(ctx: *anyopaque, key: []const u8) CacheError!bool {
        const self: *LegacyCache = @ptrCast(@alignCast(ctx));
        return self.map.contains(key);
    }

    fn legacyDelete(ctx: *anyopaque, key: []const u8) CacheError!void {
        const self: *LegacyCache = @ptrCast(@alignCast(ctx));
        if (self.map.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
    }

    fn legacyDeinit(ctx: *anyopaque) void {
        const self: *LegacyCache = @ptrCast(@alignCast(ctx));
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit(self.allocator);
    }
};

test "Cache.getOwned 对未提供该槽位的既有实现：仍可编译并退化为 get+dupe" {
    const allocator = std.testing.allocator;
    var legacy = LegacyCache{ .allocator = allocator };
    const c = legacy.asCache();
    defer c.deinit();

    try c.set("k", "legacy_value", 60);

    // 编译期证据：`LegacyCache.legacy_vtable` 没有写 `getOwned` 字段仍能构造
    // （默认 null）；运行期证据：退化路径仍然返回内容正确的所有权副本。
    try std.testing.expect(c.vtable.getOwned == null);
    const copy = (try c.getOwned(allocator, "k")) orelse return error.TestUnexpectedResult;
    defer allocator.free(copy);
    try std.testing.expectEqualStrings("legacy_value", copy);

    // 副本独立于缓存内容：写 / 删之后依然完好。
    try c.set("k", "changed", 60);
    try std.testing.expectEqualStrings("legacy_value", copy);
    try c.delete("k");
    try std.testing.expectEqualStrings("legacy_value", copy);

    // 未命中返回 null。
    try std.testing.expect((try c.getOwned(allocator, "missing")) == null);
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
