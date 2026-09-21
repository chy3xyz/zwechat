#!/usr/bin/env bash
#
# tools/api_surface_check.sh — 公开 API 面快照 + CHANGELOG 对账门禁
#
# 由来：v0.4.4 的 CHANGELOG 列了 5 条公开 API 变更，但一处真实的字段改名
# （`Button.type_` → `Button.type`）没写进去，下游是靠**编译失败**才发现的。
# 本门禁把「公开 API 面」固化成 api/surface.txt：任何 pub 声明/字段的
# 删除、改名、改类型都会让快照对不上，从而要求变更方显式去 CHANGELOG 交代。
#
# ── 维护方式（重要）───────────────────────────────────────────────────────────
#   1. 有意改名 / 删除 / 改类型公开 API 时，必须两件事一起做：
#        a) tools/api_surface_check.sh --update     # 刷新 api/surface.txt
#        b) 在 CHANGELOG.md 的**最新版本段落**或 **[Unreleased] 段落**里写明
#           被删除/改名的**旧符号名**，且必须写到容器一级：
#             pub 类型字段/方法 → `容器.旧名`（如 `Button.type_`）
#             内联匿名类型字段 → `容器.字段.子字段`（如 `OpenidList.data.openid`；
#                                写成末两段 `data.openid` 也认）
#             顶层（文件级）声明 → 直接写名字（如 `getMediaList`）
#   2. 判定结果分四档：
#        完整名命中      → 通过
#        末两段命中      → 通过（打印建议补全容器名）
#        仅历史段落命中  → 通过（打印「快照已过期」告警，鼓励尽快 --update）
#        裸叶名命中 / 完全没命中 → exit 1（打印缺记录的符号与写法指引）
#      不认「裸叶名」是因为 `type` / `init` / `send` 这类通用词在正文里到处都是：
#      曾实测若认裸名，本门禁会放过 `Button.type_` → `Button.type` 这次真实改名。
#   3. 纯新增 API（只增不删）：门禁放行，但打印新增清单，请在 CHANGELOG 的
#      `### Added` 段落补记录，并顺手 `--update`。
#   4. 发版前建议跑一次 `--update`，把快照与 CHANGELOG 一起提交，避免快照停留在旧版本。
#
# ── 用法 ────────────────────────────────────────────────────────────────────
#   tools/api_surface_check.sh            # 校验（CI 用，差异时 exit 1）
#   tools/api_surface_check.sh --update   # 用当前源码刷新 api/surface.txt
#   tools/api_surface_check.sh --help
#
# 依赖：bash + awk + find + sort + grep + sed + cmp + comm + mktemp（无网络依赖）。
# 提取逻辑见 tools/api_surface.awk（含口径说明与已知漏报）。

set -euo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNAPSHOT_REL="api/surface.txt"
SNAPSHOT="$ROOT/$SNAPSHOT_REL"
AWK_TOOL_REL="tools/api_surface.awk"
CHANGELOG="$ROOT/CHANGELOG.md"

read -r -d '' HEADER <<'EOF' || true
# api/surface.txt — zwechat 公开 API 面快照（发版纪律门禁，不要手改）
# 生成 / 校验：tools/api_surface_check.sh（--update 刷新；判定语义见脚本顶部注释）
# 格式：<文件>: pub fn|const|var <容器>.<名称>  |  <文件>: field <容器>.<字段>: <类型>
# 口径：src/ 下所有「被 pub 标注的声明」，以及 pub 类型（含其内联匿名子类型）的字段；
#       函数体 / test 块 / 私有类型内部一律不计。字段行不带 pub 前缀是因为 Zig 无私有字段。
EOF

usage() {
  cat <<'EOF'
用法：tools/api_surface_check.sh [--update | --help]

  （无参数）  用源码重新生成快照并校验 api/surface.txt 是否一致；
              存在未在 CHANGELOG 交代的删除/改名时 exit 1。
  --update    用当前源码刷新 api/surface.txt。
  --help      显示本帮助。

有意改名/删除公开 API 时：先跑 --update，再在 CHANGELOG.md 的最新版本段落或
[Unreleased] 段落写明旧名字，两者一起提交。
EOF
}

# 快照里的条目数（不含头部注释行）。
count_entries() {
  grep -vc '^#' "$1" 2>/dev/null || true
}

# 用当前源码生成快照到 stdout（头部注释 + 排序后的条目）。
generate() {
  local list
  printf '%s\n' "$HEADER"
  list="$(cd "$ROOT" && find src -type f -name '*.zig' | sort)"
  # 文件名均为 ASCII 且不含空白，故按空白切分传参是安全的。
  # shellcheck disable=SC2086
  (cd "$ROOT" && awk -f "$AWK_TOOL_REL" $list) | sort -u
}

# 从快照差异行里取出符号名：
#   `路径: pub fn 容器.名字` → 容器.名字
#   `路径: field 容器.字段: 类型` → 容器.字段
# 只用 BRE（BSD sed 不支持 `\|` 交替）。
symbol_of() {
  sed -e 's/^[^:]*: //' \
    -e 's/^field //' \
    -e 's/^pub fn //' \
    -e 's/^pub const //' \
    -e 's/^pub var //' \
    -e 's/: .*$//'
}

# 在文件中按「整词」搜索符号名（`type` 不会命中 `ReplyMsgType`）。
# 用 awk 的 index() 逐处匹配，避免任何正则转义问题（POSIX awk 即可）。
matches_token() {
  awk -v needle="$1" '
    {
      n = length(needle)
      if (n == 0) exit 1
      line = $0
      pos = 1
      while ((i = index(substr(line, pos), needle)) > 0) {
        s = pos + i - 1
        before = (s == 1) ? "" : substr(line, s - 1, 1)
        after = substr(line, s + n, 1)
        if (before !~ /[A-Za-z0-9_]/ && after !~ /[A-Za-z0-9_]/) { found = 1; exit }
        pos = s + 1
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$2"
}

# 抽「最新版本段落」+「[Unreleased] 段落」正文（不含 `##` 标题行）。
latest_and_unreleased() {
  awk '
    /^##[ \t]*\[/ { nsec++; capture = (nsec == 1) || ($0 ~ /\[Unreleased\]/); next }
    capture { print }
  ' "$CHANGELOG"
}

# 该符号是否在 CHANGELOG 任意段落有记录（用于区分「快照过期」与「完全没写」）。
# 这里只认**完整符号名**（容器.名字），不接受裸名回退，否则 `init`/`send` 这类
# 通用叶名会在历史段落里误命中，把真正漏记的改名放过去。
anywhere_in_changelog() {
  matches_token "$1" "$CHANGELOG"
}

main() {
  case "${1:-}" in
    --update)
      mkdir -p "$(dirname "$SNAPSHOT")"
      generate > "$SNAPSHOT"
      printf '已刷新 %s（共 %s 行，其中条目 %s 条）\n' \
        "$SNAPSHOT_REL" "$(wc -l < "$SNAPSHOT" | tr -d ' ')" "$(count_entries "$SNAPSHOT")"
      exit 0
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    "")
      ;;
    *)
      printf '未知参数：%s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac

  if [ ! -f "$SNAPSHOT" ]; then
    printf '缺少 %s。请先运行：tools/api_surface_check.sh --update\n' "$SNAPSHOT_REL" >&2
    exit 1
  fi

  local tmp keys_tmp sec_tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/api_surface.XXXXXX")"
  keys_tmp="$(mktemp "${TMPDIR:-/tmp}/api_keys.XXXXXX")"
  sec_tmp="$(mktemp "${TMPDIR:-/tmp}/api_sec.XXXXXX")"
  trap 'rm -f "$tmp" "$keys_tmp" "$sec_tmp" 2>/dev/null || true' EXIT

  generate > "$tmp"

  if cmp -s "$SNAPSHOT" "$tmp"; then
    printf '公开 API 面与 %s 一致（%s 条）。\n' \
      "$SNAPSHOT_REL" "$(count_entries "$SNAPSHOT")"
    exit 0
  fi

  local removed added removed_n added_n
  removed="$(comm -23 "$SNAPSHOT" "$tmp" | grep -v '^#' || true)"
  added="$(comm -13 "$SNAPSHOT" "$tmp" | grep -v '^#' || true)"
  removed_n="$(printf '%s' "$removed" | grep -c . || true)"
  added_n="$(printf '%s' "$added" | grep -c . || true)"

  if [ -z "$removed" ]; then
    printf '公开 API 面新增 %s 条，无删除/改名。\n' "$added_n"
    printf '\n新增条目（请在 CHANGELOG.md 的 Added 段落补记录，然后 --update）：\n'
    printf '%s\n' "$added" | sed 's/^/  + /'
    exit 0
  fi

  # 被删除/改名的符号名（去掉路径前缀与类型后缀）
  printf '%s\n' "$removed" | symbol_of | sort -u > "$keys_tmp"
  latest_and_unreleased > "$sec_tmp"

  local missing="" loose="" bare="" stale="" key leaf tail2
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    leaf="${key##*.}"
    # ① 完整符号名（如 `Button.type` / `work.kf.syncMsg` 里的 `Kf.syncMsg`）
    if matches_token "$key" "$sec_tmp"; then continue; fi
    # ② 深路径（含 ≥2 个点，即内联匿名类型的字段）放宽到「末两段」：
    #    `OpenidList.data.openid` 允许写成 `data.openid`。
    tail2="${key#*.}"
    case "$tail2" in
      *.*)
        if matches_token "$tail2" "$sec_tmp"; then loose="$loose$key"$'\n'; continue; fi
        ;;
    esac
    # ③ 只在历史段落出现过 → 快照过期（放行但告警）
    if anywhere_in_changelog "$key"; then stale="$stale$key"$'\n'; continue; fi
    # ④ 只找到「裸叶名」→ 仍算漏记：通用叶名（type / init / send）几乎必然
    #    在某处正文里出现过，若就此放行，门禁会被这类词整体废掉。
    if [ "$leaf" != "$key" ] && matches_token "$leaf" "$sec_tmp"; then bare="$bare$key"$'\n'; continue; fi
    missing="$missing$key"$'\n'
  done < "$keys_tmp"

  printf '公开 API 面与 %s 不一致：删除/改名 %s 条，新增 %s 条。\n\n' \
    "$SNAPSHOT_REL" "$removed_n" "$added_n"
  printf '消失的条目：\n'
  printf '%s\n' "$removed" | sed 's/^/  - /'

  if [ -n "${loose:-}" ]; then
    printf '\n以下符号按「末两段」在 CHANGELOG 命中，视为已交代（建议补上完整容器名）：\n'
    printf '%s' "$loose" | sed '/^$/d; s/^/  ~ /'
  fi

  if [ -n "${stale:-}" ]; then
    printf '\n注意：以下符号只在 CHANGELOG 的**历史**段落出现（最新段落/[Unreleased] 里没有），\n'
    printf '      说明 %s 已经过期，本次放行但请尽快补写记录并 --update：\n' "$SNAPSHOT_REL"
    printf '%s' "$stale" | sed '/^$/d; s/^/  ! /'
  fi

  if [ -n "$bare" ]; then
    printf '\n以下符号的**裸名**在 CHANGELOG 最新段落/[Unreleased] 里出现过，但没有写清容器名，\n'
    printf '不足以证明记的就是这次变更（例如裸名 `type` 可能只是在讲 `msg_type`）：\n'
    printf '%s' "$bare" | sed '/^$/d; s/^/  ✗ /'
  fi

  if [ -n "$missing" ]; then
    printf '\n以下被删除/改名的符号在 CHANGELOG.md 的最新版本段落与 [Unreleased] 段落里找不到记录：\n'
    printf '%s' "$missing" | sed '/^$/d; s/^/  ✗ /'
  fi

  if [ -n "$missing" ] || [ -n "$bare" ]; then
    cat <<'EOF'

请按下面两步处理：
  1) 若这是有意变更：在 CHANGELOG.md 的最新版本段落或 [Unreleased] 段落写明改名/删除，
     并且必须写**完整的旧符号名**（限定到容器，才能证明记的是这个符号）：
       pub 类型字段/方法 → `容器.旧名`          例如 `Button.type_`
       内联匿名类型的字段 → `容器.字段.子字段`   例如 `OpenidList.data.openid`
       顶层（文件级）声明 → 直接写名字           例如 `getMediaList`
     然后运行 tools/api_surface_check.sh --update，并把 api/surface.txt 与 CHANGELOG.md 一起提交。
  2) 若这是误改：把公开 API 改回去，不要动 api/surface.txt。

规则：pub 声明与结构体字段的删除/改名/改类型都属于「下游会编译失败」的变更，
必须同时更新快照与 CHANGELOG。
EOF
    exit 1
  fi

  printf '\n上述删除/改名都已在 CHANGELOG 交代。请再运行一次以刷新快照并提交：\n'
  printf '  tools/api_surface_check.sh --update\n'
  exit 0
}

main "$@"
