# tools/api_surface.awk — 从 src/ 源码文本提取 zwechat 的公开 API 面
#
# ⚠ 已被 tools/api_surface.zig（基于 std.zig.Ast 的真实语法树）取代：
#   tools/api_surface_check.sh 现在调用的是那个 Zig 工具，本文件**不再进入门禁路径**。
#   保留它是因为它是「独立的第二实现」，可用来交叉校验新工具的旧口径行有没有漂移：
#     cd <仓库根> && diff \
#       <(awk -f tools/api_surface.awk $(find src -type f -name '*.zig' | sort) | sort -u) \
#       <(zig run tools/api_surface.zig | grep -v ': sig ' | sort -u)
#   两条命令的输出必须逐行相同（移植当时实测 6472 行零差异）。
#   注意：`sig` 行（函数签名）只有新工具会输出，交叉校验时必须过滤掉。
#
# 用法（在仓库根目录）：
#   awk -f tools/api_surface.awk $(find src -type f -name '*.zig' | LC_ALL=C sort)
#
# 输出：每行 `<相对路径>: <条目>`，条目形如
#   pub fn <容器>.<名称>
#   pub const|var <容器>.<名称>
#   field <容器>.<字段>: <类型>
# 排序 / 头部注释 / 落盘由 tools/api_surface_check.sh 负责。
#
# 判定口径（= 「下游 import 本库后能看到的、被显式 pub 标注的声明」）：
#   * 只有出现在 pub 声明的容器类型内部的条目才算公开面；
#     函数体、test 块、comptime 块、私有的文件级类型（测试 stub 等）内部一律不计。
#   * Zig 没有「私有字段」，因此 pub 类型（含其内联匿名子类型）的字段全部计入。
#   * pub const 只记名字不记值：URL/字符串常量的取值修正不会造成快照抖动。
#
# 已知漏报：
#   1) 构造函数返回值里带出的私有类型（如 `pub fn get() *Internal`）的内部声明不计。
#   2) 跨文件的类型别名不会展开（别名本身会记为一条 pub const）。
#   3) 函数签名只记名字，不记参数类型/返回类型 —— 参数改名/改类型不会触发快照变化。
#   4) `\\` 多行字符串内部的内容不参与扫描（这是刻意的：其中可能含 {} 与类代码文本）。

BEGIN { reset_file() }

FNR == 1 { reset_file(); cur = FILENAME }

{ process_line($0) }

function reset_file() {
    nctx = 0
    stmt = ""
    paren = 0
    in_mls = 0
}

function trim(s) {
    gsub(/^[ \t]+/, "", s)
    gsub(/[ \t]+$/, "", s)
    return s
}

function norm(s) {
    gsub(/[ \t\r\n]+/, " ", s)
    return trim(s)
}

# ── 主流程 ───────────────────────────────────────────────────────────────────

function process_line(raw,   code) {
    if (in_mls) {
        if (raw ~ /^[ \t]*\\\\/) return
        in_mls = 0
    }
    code = strip(raw)
    if (code != "") walk(code)
}

# 去掉行注释与字符串/字符字面量的「内容」，只留下结构性代码。
# `@"..."` 形式的标识符原样保留（`@"type"` 是合法字段名）。
function strip(raw,   i, n, rest, out, c, k, ch, j) {
    out = ""
    i = 1
    n = length(raw)
    while (i <= n) {
        rest = substr(raw, i)
        if (match(rest, /["'\/\\]/) == 0) { out = out rest; break }
        k = i + RSTART - 1
        out = out substr(raw, i, k - i)
        c = substr(raw, k, 1)
        if (c == "/") {
            if (substr(raw, k + 1, 1) == "/") break   # 行注释，丢弃行尾
            out = out "/"
            i = k + 1
            continue
        }
        if (c == "\\") {
            if (substr(raw, k + 1, 1) == "\\") { in_mls = 1; break }   # 多行字符串开始
            out = out "\\"
            i = k + 1
            continue
        }
        if (c == "\"") {
            j = k + 1
            while (j <= n) {
                ch = substr(raw, j, 1)
                if (ch == "\\") { j += 2; continue }
                if (ch == "\"") { j++; break }
                j++
            }
            if (k > 1 && substr(raw, k - 1, 1) == "@") out = out substr(raw, k, j - k)
            else out = out "\"\""
            i = j
            continue
        }
        # c == "'"
        j = k + 1
        while (j <= n) {
            ch = substr(raw, j, 1)
            if (ch == "\\") { j += 2; continue }
            if (ch == "'") { j++; break }
            j++
        }
        out = out "''"
        i = j
    }
    return out
}

# 逐字符走一遍结构性代码：维护「语句缓冲 stmt」与「括号深度 paren」，
# 遇到 `{` `}` `;` `,` 时结算当前语句。
function walk(code,   i, n, rest, k, c) {
    i = 1
    n = length(code)
    while (i <= n) {
        rest = substr(code, i)
        if (match(rest, /[(){};,]/) == 0) { stmt = stmt rest; break }
        k = i + RSTART - 1
        stmt = stmt substr(code, i, k - i)
        c = substr(code, k, 1)
        if (c == "(") { paren++; stmt = stmt "(" }
        else if (c == ")") { if (paren > 0) paren--; stmt = stmt ")" }
        else if (c == ";") boundary(";")
        else if (c == ",") {
            # 逗号只在 pub 类型体内部（成员列表）才是语句边界；
            # 圆括号内的逗号（函数签名/调用实参）永远不是。
            if (paren == 0 && member_scope()) boundary(",")
            else stmt = stmt ","
        }
        else boundary(c)   # `{` 或 `}`
        i = k + 1
    }
}

function boundary(b,   s) {
    s = trim(stmt)
    stmt = ""
    if (b == "{") { finalize(s); open_ctx(s) }
    else if (b == "}") { finalize(s); pop_ctx() }
    else finalize(s)
}

# ── 作用域判定 ───────────────────────────────────────────────────────────────

# 当前位置是否属于公开面：所有外层上下文都是 pub 声明的类型（文件级则无外层）。
function pub_scope(   d) {
    for (d = 1; d <= nctx; d++)
        if (ctx_kind[d] != "type" || !ctx_pub[d]) return 0
    return 1
}

# 当前位置是否是 pub 类型体的「成员列表」层级。
function member_scope(   d) {
    if (nctx == 0) return 0
    if (ctx_kind[nctx] != "type" || !ctx_pub[nctx]) return 0
    for (d = 1; d < nctx; d++)
        if (ctx_kind[d] != "type" || !ctx_pub[d]) return 0
    return 1
}

function pop_ctx() {
    if (nctx > 0) nctx--
}

function push_ctx(kind, pub, name) {
    nctx++
    ctx_kind[nctx] = kind
    ctx_pub[nctx] = pub
    ctx_name[nctx] = name
}

# 用 `{` 之前的语句文本判定这个大括号是什么：类型体 / 函数体 / 测试块 / 普通块。
function open_ctx(s,   tk, n, kind, pub, name, ip, nm) {
    kind = "block"; pub = 0; name = ""
    if (s ~ /^test([ \t]|$)/) kind = "test"
    else if (s ~ /(^|[^A-Za-z0-9_])fn([ \t(]|$)/) kind = "fn"
    else if (s ~ /(^|[^A-Za-z0-9_])(struct|union|enum|opaque)[ \t]*(\([^)]*\))?$/) {
        kind = "type"
        n = split(s, tk, /[ \t]+/)
        if (n >= 3 && tk[1] == "pub" && (tk[2] == "const" || tk[2] == "var")) {
            pub = 1
            name = clean_name(tk[3])
        } else if (n >= 2 && (tk[1] == "const" || tk[1] == "var")) {
            name = clean_name(tk[2])
        } else if (member_scope()) {
            # 内联匿名类型成员：`data: struct {` / `text: enum {`
            ip = index(s, ":")
            if (ip > 0) {
                nm = trim(substr(s, 1, ip - 1))
                if (nm ~ /^(@?"[^"]*"|[A-Za-z_][A-Za-z0-9_]*)$/) { pub = 1; name = unquote(nm) }
            }
        }
    }
    push_ctx(kind, pub, name)
}

# ── 条目抽取 ─────────────────────────────────────────────────────────────────

function finalize(s,   tk, n, name, ip, ie, typ) {
    if (s == "") return
    if (s ~ /^pub[ \t]/) {
        if (!pub_scope()) return
        n = split(s, tk, /[ \t]+/)
        if (n < 3) return
        if (tk[2] != "fn" && tk[2] != "const" && tk[2] != "var") return
        name = clean_name(tk[3])
        if (name == "") return
        emit("pub " tk[2] " " qual(name))
        return
    }
    if (!member_scope()) return
    if (s !~ /^@?"?[A-Za-z_]/) return
    ip = index(s, ":")
    ie = index(s, "=")
    if (ip > 0 && (ie == 0 || ip < ie)) {
        name = trim(substr(s, 1, ip - 1))
        typ = norm(ie > 0 ? substr(s, ip + 1, ie - ip - 1) : substr(s, ip + 1))
        if (typ == "") return          # 形如 `blk:` 的标签块，不是成员
        if (name !~ /^(@?"[^"]*"|[A-Za-z_][A-Za-z0-9_]*)$/) return
        emit("field " qual(unquote(name)) ": " typ)
        return
    }
    if (ie > 0) name = trim(substr(s, 1, ie - 1))
    else name = trim(s)
    if (name !~ /^(@?"[^"]*"|[A-Za-z_][A-Za-z0-9_]*)$/) return
    emit("field " qual(unquote(name)))
}

function clean_name(s,   i, n, out, c) {
    out = ""
    n = length(s)
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == "(" || c == ":" || c == "," || c == "=") break
        out = out c
    }
    return unquote(trim(out))
}

function unquote(s) {
    if (s ~ /^@".*"$/) return substr(s, 3, length(s) - 3)
    return s
}

function qual(name,   d, out) {
    out = ""
    for (d = 1; d <= nctx; d++)
        if (ctx_name[d] != "") out = out ctx_name[d] "."
    return out name
}

function emit(entry) {
    print cur ": " entry
}
