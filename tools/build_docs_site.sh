#!/usr/bin/env bash
#
# build_docs_site.sh — 用 zdoc 把仓库里的 Markdown 生成文档站点
#   项目：https://github.com/chy3xyz/zdoc
#
# 用法：
#   tools/build_docs_site.sh <zdoc 可执行文件> [输出目录=./public] [URL 前缀=/<仓库目录名>]
#
# 关于 URL 前缀：GitHub Pages 的**项目站点**服务在 https://<owner>.github.io/<repo>/ 子路径下，
# 而 zdoc 生成的是根绝对路径（`/zdoc.css`、`/docs/...`），不加前缀会整站 404。
# 用 zdoc 自带的 `--url-prefix` 解决（默认取本仓库目录名，zwechat → `/zwechat`）。
# 若以后挂到自定义域名或用户站点根目录，把第三个参数传空串即可（`''`）。
#
# 为什么是「装配」内容目录而不是直接指 `docs/`：
#   1. zdoc 要求内容根必须有 `README.md` 或 `index.md` 作为站点首页 —— 我们直接用仓库
#      根 README（单一事实来源，避免复制一份到 docs/ 后两边漂移）；
#   2. 文档里存在跨目录相对链接（`../doc/api_guide.md`、`../AGENTS.md`、`../CHANGELOG.md`），
#      所以把 `docs/` 与 `doc/` 按**仓库相对位置**复制进内容根，链接在站点上仍能解析
#      （`/docs/api-reference/` 里的 `../doc/api_guide.md` → `/doc/api_guide/`，确实存在）。
#
# 排除项：`docs/superpowers/`（内部 agent 的实施计划，不是面向使用者的文档）。
#
# ⚠ 已知 zdoc 缺陷（v0.16.0 正式版仍存在，最小复现 `## ~~abc~~`）：
#   **标题（heading）里含 `~~删除线~~` 会让目录渲染 panic**
#     `TODO: implement toc 'NONE' inline rendering` / `src/render/html.zig` 的 `tocRenderHeading`
#   （正文里的 `~~` 没事；debug 构建下报的是 `invalid enum value`，同一路径。）
#   本脚本因此在**站点副本**上把标题行里的 `~~` 去掉，仓库里的原文保持不变。
#   若 zdoc 修好了，删掉 `sanitize_headings` 一步即可（脚本会在日志里提示它生效过多少次）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZDOC="${1:-}"
OUT="${2:-$ROOT/public}"
PREFIX="${3-/$(basename "$ROOT")}"
TITLE="zwechat"

if [ -z "$ZDOC" ] || [ ! -x "$ZDOC" ]; then
  echo "用法: tools/build_docs_site.sh <zdoc 可执行文件> [输出目录]" >&2
  echo "  （zdoc 可从 https://github.com/chy3xyz/zdoc/releases 取预编译产物）" >&2
  exit 2
fi

SRC="$(mktemp -d)"
WRK="$(mktemp -d)"
cleanup() { rm -rf "$SRC" "$WRK"; }
trap cleanup EXIT

# ── 1) 装配内容目录 ────────────────────────────────────────────────────────────
# 根 README 当首页；其余根级 md 一并带上，站内互链才不断。
for f in README.md CHANGELOG.md AGENTS.md CONTRIBUTING.md NOTICE.md; do
  [ -f "$ROOT/$f" ] && cp "$ROOT/$f" "$SRC/$f"
done
# docs/ 与 doc/ 保持仓库相对位置。
mkdir -p "$SRC/docs" "$SRC/doc"
cp "$ROOT"/docs/*.md "$SRC/docs/"
cp "$ROOT"/doc/*.md "$SRC/doc/"

# ── 2) 站点侧规避「标题里的删除线」→ zdoc TOC panic ───────────────────────────
sanitized=0
while IFS= read -r -d '' f; do
  if grep -qE '^#{1,6} .*~~' "$f"; then
    sed -E -i.bak '/^#{1,6} /s/~~//g' "$f"
    rm -f "$f.bak"
    sanitized=$((sanitized + 1))
  fi
done < <(find "$SRC" -name '*.md' -print0)

# ── 3) 生成站点 ───────────────────────────────────────────────────────────────
# 输出目录必须清空：`--force` 只是允许非空目录，且**不会**删除旧文件（会留下陈页）。
rm -rf "$OUT"
mkdir -p "$OUT"
prefix_args=()
[ -n "$PREFIX" ] && prefix_args=(--url-prefix "$PREFIX")
"$ZDOC" docs "$SRC" --base "$WRK" --output "$OUT" --title "$TITLE" "${prefix_args[@]}"

# ── 4) 自检：每一页都真的生成了（zdoc 崩溃时是 SIGABRT，但万一被吞掉也要拦）────
expected=0
missing=0
while IFS= read -r -d '' f; do
  rel="${f#"$SRC"/}"
  case "$rel" in
    README.md|index.md) page="$OUT/index.html" ;;
    *) page="$OUT/${rel%.md}/index.html" ;;
  esac
  expected=$((expected + 1))
  if [ ! -f "$page" ]; then
    echo "未能生成: $rel" >&2
    missing=$((missing + 1))
  fi
done < <(find "$SRC" -name '*.md' -print0)

echo "已生成 $((expected - missing))/$expected 页 → $OUT"
[ "$sanitized" -gt 0 ] && echo "提示：为绕开 zdoc 的标题删除线缺陷，改写了 $sanitized 个文件的标题行（仅站点副本）"
[ "$missing" -eq 0 ]
