// SPDX-License-Identifier: Apache-2.0
//! test/error_set_snapshot — 公开错误集成员快照门禁
//!
//! 背景：Zig 的错误集是**结构化**的——下游对 `WechatError` / `CredentialError` /
//! `NotifyError` / `rsa_impl.Error` 做穷尽 `switch` 时，只要上游增删一个变体，
//! 下游就会编译失败。而 `tools/api_surface_check.sh` 的快照只记录类型名与函数签名，
//! **不记录错误集成员**，因此这类破坏性变更此前没有任何门禁能发现。
//!
//! 本文件把每个公开错误集的成员名固化成字符串常量数组（快照），再用
//! `@typeInfo(E).error_set.error_names` 取实际成员逐项对账：
//!
//! - 实际有、快照没有 → 新增（`extra`）；
//! - 快照有、实际没有 → 删除或改名（`missing`）。
//!
//! 任一侧非空即测试失败，并在 stderr 打印**具体多出 / 缺少的成员名**与更新指引。
//!
//! ## 增删公开错误集成员时怎么办
//!
//! 1. 修改对应错误集；
//! 2. 同步本文件里对应的 `*Snapshot` 常量（增删同名条目）；
//! 3. 在 `CHANGELOG.md` 最新段落或 `[Unreleased]` 写明该公开面变更（与
//!    `tools/api_surface_check.sh` 的门禁口径一致）。
//!
//! ## 为什么用「快照常量 + 逐项 diff」而不是直接 `expectEqual`
//!
//! - `@typeInfo` 给出的成员顺序属实现细节，比较必须是**集合语义**（顺序无关）；
//! - `expectEqualDeep` 只能报「不等」，无法指出是谁多、谁少；本文件的 `diffNames`
//!   会分别给出 `extra` / `missing` 两张名单，输出可直接照抄修正。
//!
//! ## 覆盖范围
//!
//! 当前覆盖的 19 个公开错误集：
//!
//! - `util/error.zig` 的 `WechatError`；
//! - `credential/mod.zig` 的 `CredentialError`；
//! - `pay/v3/notify.zig` 的 `NotifyError`；
//! - `util/rsa_impl.zig` 的 `Error`；
//! - `cache/mod.zig` 的 `CacheError`；
//! - `util/rsa.zig` 的 `RsaError` / `P12Error` / `Ed25519Error`；
//! - `util/asn1.zig` 的 `Error`；
//! - `util/pkcs12.zig` 的 `Error`；
//! - `util/mtls.zig` 的 `NotEnabledError`；
//! - `openplatform/context/access_token.zig` 的 `Error`；
//! - `openplatform/context/auth.zig` 的 `Error`；
//! - `openplatform/miniprogram/basic.zig` 的 `Error`；
//! - `openplatform/miniprogram/component.zig` 的 `Error`；
//! - `wechat.zig` 的 4 个工厂错误集 `Wechat.GetOfficialAccountError` /
//!   `Wechat.GetWorkError` / `Wechat.GetMiniProgramError` / `Wechat.GetOpenPlatformError`。
//!
//! 组合错误集（`CredentialError = std.json.Error || Allocator.Error || CacheError ||
//! error{...}`、`access_token.Error = error{...} || WechatError || CacheError ||
//! Allocator.Error`、`auth/basic/component.Error = access_token.Error || error{...}`）
//! 按 `@typeInfo` **展开后的全部实际成员**快照（重复成员去重）——下游穷尽 `switch`
//! 面对的就是这个展开集合。
//!
//! 快照常量刻意保持**私有**（非 `pub`）：它们是测试夹具，不该出现在公开 API 面上。

const std = @import("std");

const util_error = @import("../util/error.zig");
const credential = @import("../credential/mod.zig");
const notify = @import("../pay/v3/notify.zig");
const rsa_impl = @import("../util/rsa_impl.zig");
const cache_mod = @import("../cache/mod.zig");
const op_access_token = @import("../openplatform/context/access_token.zig");
const op_auth = @import("../openplatform/context/auth.zig");
const op_basic = @import("../openplatform/miniprogram/basic.zig");
const op_component = @import("../openplatform/miniprogram/component.zig");
const rsa = @import("../util/rsa.zig");
const pkcs12 = @import("../util/pkcs12.zig");
const asn1 = @import("../util/asn1.zig");
const mtls = @import("../util/mtls.zig");
const wechat_mod = @import("../wechat.zig");

// -----------------------------------------------------------------------------
// 快照（成员名，顺序无关）
// -----------------------------------------------------------------------------

const WechatErrorSnapshot = [_][]const u8{
    "ApiError",
    "NetworkError",
    "DecodeError",
    "AccessTokenExpired",
    "ConfigMissing",
    "InvalidArgument",
    "TransportMisconfigured",
};

const CredentialErrorSnapshot = [_][]const u8{
    // std.json.Error
    "SyntaxError",
    "UnexpectedEndOfInput",
    // std.mem.Allocator.Error
    "OutOfMemory",
    // cache.CacheError
    "NotFound",
    "TypeMismatch",
    "StorageError",
    // credential 自有
    "ApiError",
    "HttpError",
    "DecodeError",
    "ConfigMissing",
};

const NotifyErrorSnapshot = [_][]const u8{
    "MissingSignatureHeader",
    "InvalidTimestamp",
    "TimestampOutOfWindow",
    "SignatureInvalid",
    "SerialNotFound",
    "PlatformCertFetchFailed",
    "CertParseFailed",
    "ApiV3KeyRequired",
    "MissingPrivateKey",
    "MissingMchId",
    "ConfigMissing",
    "OutOfMemory",
};

const RsaImplErrorSnapshot = [_][]const u8{
    "InvalidPemKey",
    "InvalidSignature",
    "UnsupportedKeyFormat",
    "OutOfMemory",
    "EncodingFailed",
    "InvalidDer",
    "UnsupportedTag",
    "InvalidCiphertext",
};

/// `cache.CacheError`（4 项）：独立错误集，同时作为 `CredentialError` 与
/// `openplatform/context/access_token.Error` 的组成成员被间接覆盖。
const CacheErrorSnapshot = [_][]const u8{
    "NotFound",
    "TypeMismatch",
    "StorageError",
    "OutOfMemory",
};

/// `openplatform/context/access_token.Error`（15 项）：组合错误集，按 `@typeInfo`
/// 展开后的全部实际成员快照——自有 4 项 + `WechatError` 7 项 + `CacheError` 4 项，
/// 其中 `OutOfMemory` 同时来自 `CacheError` 与 `std.mem.Allocator.Error`，去重后只记一次。
const OpenPlatformAccessTokenErrorSnapshot = [_][]const u8{
    // 自有
    "VerifyTicketRequired",
    "CacheUnavailable",
    "AuthorizerAppidRequired",
    "RefreshTokenRequired",
    // util.error.WechatError
    "ApiError",
    "NetworkError",
    "DecodeError",
    "AccessTokenExpired",
    "ConfigMissing",
    "InvalidArgument",
    "TransportMisconfigured",
    // cache.CacheError（OutOfMemory 与 Allocator.Error 重合）
    "NotFound",
    "TypeMismatch",
    "StorageError",
    "OutOfMemory",
};

/// `util/rsa.zig` 的 `RsaError`（5 项）。
const RsaErrorSnapshot = [_][]const u8{
    "RsaNotImplemented",
    "InvalidPemKey",
    "InvalidSignature",
    "InvalidCiphertext",
    "OutOfMemory",
};

/// `util/rsa.zig` 的 `P12Error`（4 项）。
const P12ErrorSnapshot = [_][]const u8{
    "P12NotImplemented",
    "InvalidP12File",
    "BadPassword",
    "OutOfMemory",
};

/// `util/rsa.zig` 的 `Ed25519Error`（4 项）：Ed25519 签名/验签自有错误集。
const Ed25519ErrorSnapshot = [_][]const u8{
    "InvalidSecretKey",
    "InvalidPublicKey",
    "InvalidSignature",
    "SigningFailed",
};

/// `util/asn1.zig` 的 `Error`（3 项）：最小 DER 解析器错误集。
const Asn1ErrorSnapshot = [_][]const u8{
    "InvalidDer",
    "UnsupportedTag",
    "OutOfMemory",
};

/// `util/pkcs12.zig` 的 `Error`（6 项）：P12 解析自有 3 项 + DER 层 3 项。
const Pkcs12ErrorSnapshot = [_][]const u8{
    "InvalidP12File",
    "BadPassword",
    "UnsupportedPbe",
    "InvalidDer",
    "UnsupportedTag",
    "OutOfMemory",
};

/// `util/mtls.zig` 的 `NotEnabledError`（1 项）：`-Dmtls=false`（默认）时
/// `postXMLWithTLS` 的返回错误。
const MtlsNotEnabledErrorSnapshot = [_][]const u8{"MtlsNotEnabled"};

/// `openplatform/context/auth.zig` 的 `Error`（17 项）：组合错误集，
/// `access_token.Error`（15 项，见上）`|| error{AuthorizationCodeRequired, WriteFailed}`，
/// 无重复成员。
const OpenPlatformAuthErrorSnapshot = [_][]const u8{
    // access_token.Error（展开后的 15 项）
    "VerifyTicketRequired",
    "CacheUnavailable",
    "AuthorizerAppidRequired",
    "RefreshTokenRequired",
    "ApiError",
    "NetworkError",
    "DecodeError",
    "AccessTokenExpired",
    "ConfigMissing",
    "InvalidArgument",
    "TransportMisconfigured",
    "NotFound",
    "TypeMismatch",
    "StorageError",
    "OutOfMemory",
    // auth 自有
    "AuthorizationCodeRequired",
    "WriteFailed",
};

/// `openplatform/miniprogram/basic.zig` 的 `Error`（16 项）：组合错误集，
/// `access_token.Error`（15 项）`|| error{WriteFailed}`。
const OpenPlatformBasicErrorSnapshot = [_][]const u8{
    "VerifyTicketRequired",
    "CacheUnavailable",
    "AuthorizerAppidRequired",
    "RefreshTokenRequired",
    "ApiError",
    "NetworkError",
    "DecodeError",
    "AccessTokenExpired",
    "ConfigMissing",
    "InvalidArgument",
    "TransportMisconfigured",
    "NotFound",
    "TypeMismatch",
    "StorageError",
    "OutOfMemory",
    "WriteFailed",
};

/// `openplatform/miniprogram/component.zig` 的 `Error`（16 项）：组合错误集，
/// 与 `basic.Error` 同形——`access_token.Error`（15 项）`|| error{WriteFailed}`。
const OpenPlatformComponentErrorSnapshot = [_][]const u8{
    "VerifyTicketRequired",
    "CacheUnavailable",
    "AuthorizerAppidRequired",
    "RefreshTokenRequired",
    "ApiError",
    "NetworkError",
    "DecodeError",
    "AccessTokenExpired",
    "ConfigMissing",
    "InvalidArgument",
    "TransportMisconfigured",
    "NotFound",
    "TypeMismatch",
    "StorageError",
    "OutOfMemory",
    "WriteFailed",
};

// ── wechat.zig 顶层工厂的 4 个窄错误集 ──────────────────────────────────────
//
// 四者当前同形（`error{CacheUnavailable}`），但仍是独立声明的公开错误集，
// 各自单独快照，避免未来其中一个独立演进时被"看起来一样"掩盖。

/// `Wechat.GetOfficialAccountError`（1 项）。
const GetOfficialAccountErrorSnapshot = [_][]const u8{"CacheUnavailable"};

/// `Wechat.GetWorkError`（1 项）。
const GetWorkErrorSnapshot = [_][]const u8{"CacheUnavailable"};

/// `Wechat.GetMiniProgramError`（1 项）。
const GetMiniProgramErrorSnapshot = [_][]const u8{"CacheUnavailable"};

/// `Wechat.GetOpenPlatformError`（1 项）。
const GetOpenPlatformErrorSnapshot = [_][]const u8{"CacheUnavailable"};

// -----------------------------------------------------------------------------
// 反射 / 对账
// -----------------------------------------------------------------------------

/// 取错误集 `E` 的全部成员名。
///
/// `E` 必须是具名错误集（`anyerror` 没有固定成员，会 `@compileError`）。
/// 返回的切片在编译期构造，与错误集成员一一对应。
fn errorSetNames(comptime E: type) []const []const u8 {
    comptime {
        // 组合错误集展开后成员可达成对，`diffNames` 的两两比对会消耗大量
        // 逆分支配额（默认 1000 不够），这里统一抬高。
        @setEvalBranchQuota(10_000);
        const names = switch (@typeInfo(E)) {
            .error_set => |es| es.error_names orelse
                @compileError("errorSetNames 不支持 anyerror（无固定成员）"),
            else => @compileError("errorSetNames 只接受错误集，收到 " ++ @typeName(E)),
        };
        var out: []const []const u8 = &.{};
        for (names) |n| out = out ++ &[_][]const u8{n};
        return out;
    }
}

/// 两张名单：`extra` = 实际有但快照缺（新增）；`missing` = 快照有但实际缺（删除/改名）。
const Diff = struct {
    extra: []const []const u8,
    missing: []const []const u8,
};

fn contains(comptime haystack: []const []const u8, comptime needle: []const u8) bool {
    @setEvalBranchQuota(10_000);
    for (haystack) |h| if (std.mem.eql(u8, h, needle)) return true;
    return false;
}

/// 集合语义对账（顺序无关），结果在编译期构造。
fn diffNames(comptime actual: []const []const u8, comptime expected: []const []const u8) Diff {
    comptime {
        @setEvalBranchQuota(10_000);
        var extra: []const []const u8 = &.{};
        var missing: []const []const u8 = &.{};
        for (actual) |a| {
            if (!contains(expected, a)) extra = extra ++ &[_][]const u8{a};
        }
        for (expected) |e| {
            if (!contains(actual, e)) missing = missing ++ &[_][]const u8{e};
        }
        return .{ .extra = extra, .missing = missing };
    }
}

/// 门禁本体：把 `E` 的实际成员与 `snapshot` 对账；一致则通过，否则失败。
///
/// 这是**纯函数**（除 stderr 输出外无副作用、不做 IO），因此「快照多一项会不会红」
/// 可以用虚构错误集在测试里直接验证（见文件末尾的自检用例），不需要真的破坏某个
/// 生产错误集。
fn expectErrorSetSnapshot(
    comptime label: []const u8,
    comptime E: type,
    comptime snapshot: []const []const u8,
) error{ErrorSetSnapshotMismatch}!void {
    const actual = comptime errorSetNames(E);
    const d = comptime diffNames(actual, snapshot);
    if (d.extra.len == 0 and d.missing.len == 0) return;

    std.debug.print("\n[error_set_snapshot] 公开错误集快照失配：{s}\n", .{label});
    if (d.extra.len != 0) {
        std.debug.print("  新增成员（实际有、快照缺）{d} 个:", .{d.extra.len});
        for (d.extra) |n| std.debug.print(" {s}", .{n});
        std.debug.print("\n", .{});
    }
    if (d.missing.len != 0) {
        std.debug.print("  缺失成员（快照有、实际无，可能被删或改名）{d} 个:", .{d.missing.len});
        for (d.missing) |n| std.debug.print(" {s}", .{n});
        std.debug.print("\n", .{});
    }
    std.debug.print(
        "  修正方式：同步更新 src/test/error_set_snapshot.zig 顶部的 *Snapshot 常量，并在 CHANGELOG 记录该公开面变更。\n",
        .{},
    );
    return error.ErrorSetSnapshotMismatch;
}

// -----------------------------------------------------------------------------
// 生产门禁
// -----------------------------------------------------------------------------

test "公开错误集快照：WechatError 成员无增删" {
    try expectErrorSetSnapshot("util.error.WechatError", util_error.WechatError, &WechatErrorSnapshot);
}

test "公开错误集快照：CredentialError 成员无增删" {
    try expectErrorSetSnapshot("credential.CredentialError", credential.CredentialError, &CredentialErrorSnapshot);
}

test "公开错误集快照：pay/v3 NotifyError 成员无增删" {
    try expectErrorSetSnapshot("pay.v3.notify.NotifyError", notify.NotifyError, &NotifyErrorSnapshot);
}

test "公开错误集快照：util/rsa_impl Error 成员无增删" {
    try expectErrorSetSnapshot("util.rsa_impl.Error", rsa_impl.Error, &RsaImplErrorSnapshot);
}

test "公开错误集快照：cache CacheError 成员无增删" {
    try expectErrorSetSnapshot("cache.CacheError", cache_mod.CacheError, &CacheErrorSnapshot);
}

test "公开错误集快照：openplatform/context/access_token Error 成员无增删" {
    try expectErrorSetSnapshot(
        "openplatform.context.access_token.Error",
        op_access_token.Error,
        &OpenPlatformAccessTokenErrorSnapshot,
    );
}

test "公开错误集快照：util/rsa RsaError 成员无增删" {
    try expectErrorSetSnapshot("util.rsa.RsaError", rsa.RsaError, &RsaErrorSnapshot);
}

test "公开错误集快照：util/rsa P12Error 成员无增删" {
    try expectErrorSetSnapshot("util.rsa.P12Error", rsa.P12Error, &P12ErrorSnapshot);
}

test "公开错误集快照：util/rsa Ed25519Error 成员无增删" {
    try expectErrorSetSnapshot("util.rsa.Ed25519Error", rsa.Ed25519Error, &Ed25519ErrorSnapshot);
}

test "公开错误集快照：util/asn1 Error 成员无增删" {
    try expectErrorSetSnapshot("util.asn1.Error", asn1.Error, &Asn1ErrorSnapshot);
}

test "公开错误集快照：util/pkcs12 Error 成员无增删" {
    try expectErrorSetSnapshot("util.pkcs12.Error", pkcs12.Error, &Pkcs12ErrorSnapshot);
}

test "公开错误集快照：util/mtls NotEnabledError 成员无增删" {
    try expectErrorSetSnapshot("util.mtls.NotEnabledError", mtls.NotEnabledError, &MtlsNotEnabledErrorSnapshot);
}

test "公开错误集快照：openplatform/context/auth Error 成员无增删" {
    try expectErrorSetSnapshot(
        "openplatform.context.auth.Error",
        op_auth.Error,
        &OpenPlatformAuthErrorSnapshot,
    );
}

test "公开错误集快照：openplatform/miniprogram/basic Error 成员无增删" {
    try expectErrorSetSnapshot(
        "openplatform.miniprogram.basic.Error",
        op_basic.Error,
        &OpenPlatformBasicErrorSnapshot,
    );
}

test "公开错误集快照：openplatform/miniprogram/component Error 成员无增删" {
    try expectErrorSetSnapshot(
        "openplatform.miniprogram.component.Error",
        op_component.Error,
        &OpenPlatformComponentErrorSnapshot,
    );
}

test "公开错误集快照：wechat GetOfficialAccountError 成员无增删" {
    try expectErrorSetSnapshot(
        "wechat.Wechat.GetOfficialAccountError",
        wechat_mod.Wechat.GetOfficialAccountError,
        &GetOfficialAccountErrorSnapshot,
    );
}

test "公开错误集快照：wechat GetWorkError 成员无增删" {
    try expectErrorSetSnapshot(
        "wechat.Wechat.GetWorkError",
        wechat_mod.Wechat.GetWorkError,
        &GetWorkErrorSnapshot,
    );
}

test "公开错误集快照：wechat GetMiniProgramError 成员无增删" {
    try expectErrorSetSnapshot(
        "wechat.Wechat.GetMiniProgramError",
        wechat_mod.Wechat.GetMiniProgramError,
        &GetMiniProgramErrorSnapshot,
    );
}

test "公开错误集快照：wechat GetOpenPlatformError 成员无增删" {
    try expectErrorSetSnapshot(
        "wechat.Wechat.GetOpenPlatformError",
        wechat_mod.Wechat.GetOpenPlatformError,
        &GetOpenPlatformErrorSnapshot,
    );
}

// -----------------------------------------------------------------------------
// 自检：证明门禁在「快照与实际不一致」时**真的会失败**
// -----------------------------------------------------------------------------

const fake_set = error{ Alpha, Beta };

/// 比 `fake_set` 多一项（模拟「快照多写了 / 成员被删除」）。
const fake_extra_snapshot = [_][]const u8{ "Alpha", "Beta", "Gamma" };
/// 比 `fake_set` 少一项（模拟「新增成员但快照没更新」）。
const fake_missing_snapshot = [_][]const u8{"Alpha"};

test "自检：快照多一个成员 → 报 missing 且门禁失败" {
    const d = comptime diffNames(errorSetNames(fake_set), &fake_extra_snapshot);
    try std.testing.expectEqual(@as(usize, 0), d.extra.len);
    try std.testing.expectEqual(@as(usize, 1), d.missing.len);
    try std.testing.expectEqualStrings("Gamma", d.missing[0]);

    try std.testing.expectError(
        error.ErrorSetSnapshotMismatch,
        expectErrorSetSnapshot("self-check/快照多一项", fake_set, &fake_extra_snapshot),
    );
}

test "自检：实际多一个成员 → 报 extra 且门禁失败" {
    const d = comptime diffNames(errorSetNames(fake_set), &fake_missing_snapshot);
    try std.testing.expectEqual(@as(usize, 1), d.extra.len);
    try std.testing.expectEqual(@as(usize, 0), d.missing.len);
    try std.testing.expectEqualStrings("Beta", d.extra[0]);

    try std.testing.expectError(
        error.ErrorSetSnapshotMismatch,
        expectErrorSetSnapshot("self-check/实际多一项", fake_set, &fake_missing_snapshot),
    );
}

test "自检：成员一致（顺序无关）时门禁通过" {
    const reordered = [_][]const u8{ "Beta", "Alpha" };
    try expectErrorSetSnapshot("self-check/顺序无关", fake_set, &reordered);
}

test "自检：errorSetNames 取到全部成员名" {
    const names = comptime errorSetNames(fake_set);
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("Alpha", names[0]);
    try std.testing.expectEqualStrings("Beta", names[1]);
}

test "自检：组合错误集按 @typeInfo 展开（合并 std 与自有成员）" {
    const Combo = std.json.Error || error{ OwnedOne, OwnedTwo };
    const names = comptime errorSetNames(Combo);
    // std.json.Error 至少含 SyntaxError；自有成员必须在场。
    try std.testing.expect(contains(names, "SyntaxError"));
    try std.testing.expect(contains(names, "OwnedOne"));
    try std.testing.expect(contains(names, "OwnedTwo"));
    try std.testing.expect(!contains(names, "NotAMember"));
}
