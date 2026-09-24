// SPDX-License-Identifier: Apache-2.0
//! tools/api_surface.zig — 用 `std.zig.Ast` 提取 zwechat 的公开 API 面
//!
//! 用法（在仓库根目录）：
//!   bash tools/api_surface_check.sh            # 门禁：算好快照后与 api/surface.txt 对账
//!   zig run tools/api_surface.zig              # 直接打印条目（扫描 ./src）
//!   zig build api-surface                      # 同上，走构建图
//!   zig run tools/api_surface.zig -- --root /path/to/repo
//!
//! 输出：每行 `<相对路径>: <条目>`，条目形如
//!   pub fn <容器>.<名称>
//!   sig <容器>.<名称>(参数类型, ...) <返回类型>
//!   pub const|var <容器>.<名称>
//!   field <容器>.<字段>: <类型>
//! 排序 / 头部注释 / 落盘由 tools/api_surface_check.sh 负责（本工具只按源码顺序
//! 逐文件输出，不做排序）。
//!
//! ── 判定口径（= 「下游 import 本库后能看到的、被显式 pub 标注的声明」）────────
//!   * 只递归进入**被 pub 标注的容器类型**（`pub const X = struct|enum|union|opaque
//!     {...}`）。函数体 / test 块 / comptime 块 / 私有类型内部一律不进入，
//!     因此函数体里的局部 `const X = struct {...}`（测试 stub、私有 VTable 等）
//!     天然不会出现在快照里。
//!   * Zig 没有「私有字段」，因此 pub 类型（含其内联匿名子类型，如
//!     `data: struct { openid: []const u8 }`）的字段全部计入；这个内联匿名类型同时
//!     成为容器名的一段（`OpenidList.data.openid`）。
//!   * `pub const` 只记名字不记值：URL / 字符串常量的取值修正不会造成快照抖动。
//!   * 枚举成员（无类型）记为 `field <容器>.<成员>`，与旧 awk 一致。
//!   * 标识符若是 `@"..."` 形式，去掉引号与 `@` 后原样记录（`@"type"` → `type`）。
//!
//! ── `sig` 行（本工具相对旧 awk 的核心增量）───────────────────────────────────
//! 旧 awk 只记函数**名字**：参数类型、返回类型、参数个数变了都看不出来（改
//! `[]const u8` → `[]u8` 这类「下游会编译失败」的变更因此漏过门禁）。现在每个
//! pub 函数额外输出一行签名：
//!   src/util/pkcs12.zig: sig parse(std.mem.Allocator, []const u8, []const u8) P12Result
//! **只记类型，不记参数名**：改参数名不破坏下游编译，记进来只会制造噪声；而改类型、
//! 增删参数、改返回类型都会让下游编译失败，必须被门禁拦住。声明没有显式返回类型时
//! （如 `extern fn`）记 `<none>`。
//! 签名行的**既有格式行一字不动**：旧行照旧输出，`sig` 是纯追加的独立行，因此
//! `api/surface.txt` 的 diff 语义向后可比（旧条目的增删仍是原来的含义）。
//!
//! ── 注释与字符串处理 ─────────────────────────────────────────────────────────
//! 类型/签名文本按 token 区间从源码还原：token 之间原本有空白（含被跳过的 `//`、
//! `///` 注释）就压成一个空格，多行写法会被拉平成一行 —— 与旧 awk 的 `norm()`
//! 语义一致。字符串/字符字面量的内容换算成 `""` / `''`（`@"name"` 标识符形式原样
//! 保留），这也是为了与旧快照逐字可比。
//!
//! ── 已知漏报 ─────────────────────────────────────────────────────────────────
//!   1) 构造函数返回值里带出的私有类型（如 `pub fn get() *Internal`）的内部声明不计。
//!   2) 跨文件的类型别名不会展开（别名本身会记为一条 pub const）。
//!   3) 条件类型（`pub const X = if (c) struct {...} else struct {...};`）里的字段不计：
//!      旧 awk 靠 `{` 猜，本工具按 AST 精确判定容器后不再「猜」。实测本仓库无此写法。
//!   4) 类型文本里的字符串字面量内容不参与对账（`@import("../../util/http.zig").Foo`
//!      记为 `@import("").Foo`）：与旧 awk 保持逐字可比，代价是改模块路径不触发门禁。

const std = @import("std");
const Ast = std.zig.Ast;

/// 单文件大小上限。源码文件远小于此，超限直接报错（而不是截断后解析出错误的 API 面）。
const max_file_bytes: usize = 16 * 1024 * 1024;

/// 收集到的 `.zig` 文件的相对路径（`src/` 前缀 + `/` 分隔）。
fn collectZigFiles(arena: std.mem.Allocator, io: std.Io, root: []const u8) ![]const []const u8 {
    const src_path = try std.fs.path.join(arena, &.{ root, "src" });
    var dir = try std.Io.Dir.cwd().openDir(io, src_path, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(arena);
    defer walker.deinit();

    var files: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const rel = try std.fmt.allocPrint(arena, "src/{s}", .{entry.path});
        // Windows 的 sep 是 `\`；统一成 `/`，让快照跨平台逐字可比。
        std.mem.replaceScalar(u8, rel, '\\', '/');
        try files.append(arena, rel);
    }
    std.mem.sort([]const u8, files.items, {}, lessThanBytes);
    return files.items;
}

fn lessThanBytes(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// 解析单个文件并把它的公开条目写进 `out`。
fn processFile(
    arena: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    root: []const u8,
    rel_path: []const u8,
) !void {
    const abs_path = try std.fs.path.join(arena, &.{ root, rel_path });
    const source = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        abs_path,
        arena,
        .limited(max_file_bytes),
        .of(u8),
        0,
    );

    var tree = try Ast.parse(arena, source, .{ .mode = .zig });
    defer tree.deinit(arena);

    if (tree.errors.len != 0) {
        // 快照是「全量重算 + 逐行对账」的语义：一个文件解析失败就等于它的条目全部
        // 消失，那会被下游误读成「API 被删了」。宁可响亮地失败，也不要生成残缺快照。
        std.debug.print(
            "api-surface：{s} 有 {d} 处语法错误，拒绝在解析失败的源码上生成快照\n",
            .{ rel_path, tree.errors.len },
        );
        return error.ParseFailed;
    }

    var walker = Walker{ .tree = tree, .out = out, .arena = arena, .path = rel_path };
    try walker.walkDecls(tree.rootDecls(), "");
}

/// 遍历一个 pub 容器的成员（`struct|enum|union|opaque` 体、或文件的顶层声明）。
const Walker = struct {
    /// 按值持有（`Ast` 只是一个装着 slices 的小结构体，复制它不影响任何所有权；
    /// `std.zig.Ast` 的多数方法按值收 tree，按指针存反而处处要 `.*`）。
    tree: Ast,
    out: *std.Io.Writer,
    arena: std.mem.Allocator,
    path: []const u8,

    /// 进入一个容器节点（若它不是容器则什么都不做）。
    ///
    /// 三个 walk* 互相递归，Zig 推不出互相依赖的 inferred error set（`dependency loop`），
    /// 因此显式写 `anyerror`；入口 `processFile` / `main` 仍是具体错误集。
    fn walkContainer(self: *Walker, node: Ast.Node.Index, qual: []const u8) anyerror!void {
        var buf: [2]Ast.Node.Index = undefined;
        const container = Ast.fullContainerDecl(self.tree, &buf, node) orelse return;
        try self.walkDecls(container.ast.members, qual);
    }

    fn walkDecls(self: *Walker, decls: []const Ast.Node.Index, qual: []const u8) anyerror!void {
        for (decls) |decl| try self.walkDecl(decl, qual);
    }

    fn walkDecl(self: *Walker, node: Ast.Node.Index, qual: []const u8) anyerror!void {
        const tree = self.tree;
        switch (tree.nodeTag(node)) {
            // fn 声明：`pub fn` 记一行名字 + 一行签名
            .fn_decl => {
                var buf: [1]Ast.Node.Index = undefined;
                const proto = Ast.fullFnProto(tree, &buf, node) orelse return;
                if (proto.visib_token == null) return;
                const name = try self.qualified(qual, tree.tokenSlice(proto.name_token orelse return));

                try self.out.print("{s}: pub fn {s}\n", .{ self.path, name });
                const signature = try self.signatureText(proto);
                try self.out.print("{s}: sig {s}{s}\n", .{ self.path, name, signature });
            },

            // 变量声明：`pub const X = struct {...}` 记名字，并在 init 真的是容器时下钻
            .simple_var_decl, .local_var_decl, .global_var_decl, .aligned_var_decl => {
                const var_decl = Ast.fullVarDecl(tree, node) orelse return;
                if (var_decl.visib_token == null) return;
                const name = try self.qualified(qual, tree.tokenSlice(var_decl.ast.mut_token + 1));
                const keyword = tree.tokenSlice(var_decl.ast.mut_token);
                try self.out.print("{s}: pub {s} {s}\n", .{ self.path, keyword, name });

                const init = var_decl.ast.init_node.unwrap() orelse return;
                const child_qual = try std.fmt.allocPrint(self.arena, "{s}.", .{name});
                try self.walkContainer(init, child_qual);
            },

            // 字段：只在 pub 容器体内才会被走到（本 Walker 不下钻别处）
            .container_field, .container_field_init, .container_field_align => {
                const field = Ast.fullContainerField(tree, node) orelse return;
                const name = try self.qualified(qual, try self.nameOf(field.ast.main_token));

                // 枚举成员 / 带默认值的成员没有「名字 : 类型」形式。这里必须看冒号而不是
                // `type_expr`：解析器对枚举成员也把「类型位置」当表达式解析，`a,` 的
                // type_expr 指向的就是 `a` 自己（按它记会得到 `field X.a: a`）。
                const type_node = if (tree.tokenTag(field.ast.main_token + 1) == .colon) blk: {
                    break :blk field.ast.type_expr.unwrap();
                } else null;
                const typed = type_node orelse {
                    try self.out.print("{s}: field {s}\n", .{ self.path, name });
                    return;
                };

                const type_text = try self.spanText(
                    tree.firstToken(typed),
                    self.typeTextEnd(typed),
                );
                try self.out.print("{s}: field {s}: {s}\n", .{ self.path, name, type_text });

                // 内联匿名容器（`data: struct {...}`）本身是字段，其成员再带一层容器名
                const child_qual = try std.fmt.allocPrint(self.arena, "{s}.", .{name});
                try self.walkContainer(typed, child_qual);
            },

            else => {},
        }
    }

    /// 类型文本的最后一个 token。内联匿名容器只到 `{` 之前：成员各自成行
    /// （`SendBody.text.content`），把 `{...}` 体也塞进这行既冗余，又会随内联类型的
    /// 实现细节抖动。
    fn typeTextEnd(self: *Walker, type_node: Ast.Node.Index) Ast.TokenIndex {
        const tree = self.tree;
        var buf: [2]Ast.Node.Index = undefined;
        if (Ast.fullContainerDecl(tree, &buf, type_node) == null) return tree.lastToken(type_node);

        const last = tree.lastToken(type_node);
        var token = tree.firstToken(type_node);
        while (token <= last) : (token += 1) {
            if (tree.tokenTag(token) == .l_brace) {
                return if (token == tree.firstToken(type_node)) token else token - 1;
            }
        }
        return last;
    }

    fn qualified(self: *Walker, qual: []const u8, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.arena, "{s}{s}", .{ qual, name });
    }

    /// `@"type"` → `type`（Zig 关键字/带特殊字符的标识符写法）。
    fn nameOf(self: *Walker, token: Ast.TokenIndex) ![]const u8 {
        const slice = self.tree.tokenSlice(token);
        if (std.mem.startsWith(u8, slice, "@\"") and std.mem.endsWith(u8, slice, "\"")) {
            return slice[2 .. slice.len - 1];
        }
        return slice;
    }

    /// `(T1, T2) Ret`：只取参数类型与返回类型，不取参数名（见文件头说明）。
    fn signatureText(self: *Walker, proto: Ast.full.FnProto) ![]const u8 {
        const tree = self.tree;
        var text: std.ArrayList(u8) = .empty;
        try text.append(self.arena, '(');

        var params = proto.iterate(&tree);
        var first = true;
        while (params.next()) |param| {
            if (!first) try text.appendSlice(self.arena, ", ");
            first = false;
            if (param.anytype_ellipsis3) |token| {
                // `anytype` / `...`：不是子表达式，token 就是类型本身
                try text.appendSlice(self.arena, tree.tokenSlice(token));
            } else if (param.type_expr) |type_node| {
                try text.appendSlice(
                    self.arena,
                    try self.spanText(tree.firstToken(type_node), tree.lastToken(type_node)),
                );
            }
        }
        try text.appendSlice(self.arena, ") ");

        if (proto.ast.return_type.unwrap()) |return_node| {
            try text.appendSlice(
                self.arena,
                try self.spanText(tree.firstToken(return_node), tree.lastToken(return_node)),
            );
        } else {
            try text.appendSlice(self.arena, "<none>");
        }
        return text.items;
    }

    /// 把 `[start, end]` 的 token 区间从源码还原成一行文本：token 之间原本有空白就
    /// 压成一个空格，注释整段丢弃（`//` 注释本来就不是 token，`///` 注释会被跳过）。
    ///
    /// 字符串/字符字面量的内容替换成 `""` / `''`（`@"name"` 标识符形式原样保留）：
    /// 与旧 awk 的快照逐字可比，也让「类型文本里改一段字符串常量」不至于造成快照抖动。
    /// 代价是类型里的 `@import("...")` 路径不参与对账（见文件头「已知漏报」）。
    fn spanText(self: *Walker, start: Ast.TokenIndex, end: Ast.TokenIndex) ![]const u8 {
        const tree = self.tree;
        var text: std.ArrayList(u8) = .empty;
        var prev_end: ?usize = null;

        var token = start;
        while (token <= end) : (token += 1) {
            const slice = switch (tree.tokenTag(token)) {
                .doc_comment, .container_doc_comment => continue,
                .string_literal => if (tree.tokenSlice(token).len > 0 and tree.tokenSlice(token)[0] == '@')
                    tree.tokenSlice(token) // `@"..."` 是标识符，原样保留
                else
                    "\"\"",
                .char_literal => "''",
                else => tree.tokenSlice(token),
            };
            if (slice.len == 0) continue; // 末尾的 eof 占位 token

            const token_start = tree.tokenStart(token);
            if (prev_end) |end_offset| {
                if (hasWhitespace(tree.source[end_offset..token_start])) {
                    try text.append(self.arena, ' ');
                }
            }
            try text.appendSlice(self.arena, slice);
            prev_end = token_start + tree.tokenSlice(token).len;
        }
        return text.items;
    }
};

fn hasWhitespace(slice: []const u8) bool {
    for (slice) |byte| {
        switch (byte) {
            ' ', '\t', '\r', '\n' => return true,
            else => {},
        }
    }
    return false;
}

fn usage(io: std.Io) !void {
    var buffer: [8 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    try stdout.interface.writeAll(
        \\用法：zig run tools/api_surface.zig [--root <仓库根目录>]
        \\
        \\  扫描 <仓库根目录>/src 下的全部 .zig 文件，把公开 API 面按 `<相对路径>: <条目>`
        \\  逐行打到 stdout（不做排序；排序与落盘由 tools/api_surface_check.sh 负责）。
        \\  无参数时 --root 取当前目录。
        \\
        \\条目格式、判定口径与已知漏报见 tools/api_surface.zig 文件头注释。
        \\
    );
    try stdout.interface.flush();
}

pub fn main(init: std.process.Init) !void {
    // 一次性工具：全程 arena，避免为每个文件、每条签名做精细的生命周期管理。
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = init.io;

    var root: []const u8 = ".";
    {
        var args = init.minimal.args.iterate();
        _ = args.next(); // 跳过程序名
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                try usage(io);
                return;
            } else if (std.mem.eql(u8, arg, "--root")) {
                root = args.next() orelse {
                    std.debug.print("api-surface：--root 后面需要一个目录参数（见 --help）\n", .{});
                    return error.MissingRoot;
                };
            } else if (std.mem.startsWith(u8, arg, "-")) {
                std.debug.print("api-surface：未知参数 {s}（见 --help）\n", .{arg});
                return error.UnknownArgument;
            } else {
                root = arg;
            }
        }
    }

    const files = try collectZigFiles(arena, io, root);

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout.interface;

    for (files) |rel_path| {
        try processFile(arena, io, out, root, rel_path);
    }
    try out.flush();
}
