#!/usr/bin/env bash
#
# 把 srt CLI 编成自带运行时的单文件二进制。
#
# srt 是 Node ESM 脚本（package.json 的 bin 指向 dist/cli.js），tsc 出来的产物
# 还要 node 才能跑。这里用 bun --compile 把 Bun 运行时一起打进去，产出一个可以
# 直接丢进 /opt/adk-runtime/bin/srt 的 ELF / Mach-O。
#
# 用法：
#   ./build-srt.sh                                    # 用 package.json 里的版本
#   ./build-srt.sh --version-code 0.0.82-gov.1        # 临时改写版本号再编
#   ./build-srt.sh --targets linux-arm64              # 只编一个目标
#   ./build-srt.sh --help
#
set -euo pipefail

DEFAULT_TARGETS="darwin-arm64 linux-x64 linux-arm64"
DIST="dist"
BASE_VERSION="0.0.82"   # ADK 侧 SRTCompatibleVersion 的基线
VERSION_CODE=""
TARGETS_ARG=""

usage() {
  cat <<'USAGE'
用法: ./build-srt.sh [选项]

选项:
  --version-code <版本>   要编进二进制的版本号，如 0.0.82-gov.1。
                          会临时改写 package.json 再构建，结束后自动恢复。
                          省略则使用 package.json 现有的 version。
  --targets "<目标列表>"  空格分隔，默认 "darwin-arm64 linux-x64 linux-arm64"。
                          可选值: darwin-arm64 darwin-x64 linux-x64 linux-arm64
  --base <基线>           ADK 要求的基线版本，默认 0.0.82。一般不用改。
  -h, --help              显示本帮助。

说明:
  版本号必须等于基线或 "<基线>-<后缀>"，否则 ADK 的 ossandbox 会拒绝启动。
  产出的二进制写在 dist/，该目录已被 .gitignore 忽略。
USAGE
}

die() { printf '\033[31m错误\033[0m %s\n' "$1" >&2; exit 1; }
note() { printf '\033[36m%s\033[0m\n' "$1"; }
warn() { printf '\033[33m警告\033[0m %s\n' "$1" >&2; }

# 实际字节数。du 报的是分配块，编译产物会明显偏大，不能用来标体积。
file_size() {
  if stat -f %z "$1" >/dev/null 2>&1; then stat -f %z "$1"; else stat -c %s "$1"; fi
}
human_size() {
  awk -v b="$1" 'BEGIN { split("B KiB MiB GiB", u, " "); i = 1
    while (b >= 1024 && i < 4) { b /= 1024; i++ }
    printf "%.1f %s", b, u[i] }'
}

# ---- 参数 ----------------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    --version-code)  [ $# -ge 2 ] || die "--version-code 需要一个值"; VERSION_CODE="$2"; shift 2 ;;
    --version-code=*) VERSION_CODE="${1#*=}"; shift ;;
    --targets)       [ $# -ge 2 ] || die "--targets 需要一个值"; TARGETS_ARG="$2"; shift 2 ;;
    --targets=*)     TARGETS_ARG="${1#*=}"; shift ;;
    --base)          [ $# -ge 2 ] || die "--base 需要一个值"; BASE_VERSION="$2"; shift 2 ;;
    --base=*)        BASE_VERSION="${1#*=}"; shift ;;
    -h|--help)       usage; exit 0 ;;
    *)               die "未知参数: $1（--help 看用法）" ;;
  esac
done

# ---- 前置检查 ------------------------------------------------------------

command -v bun >/dev/null 2>&1 || {
  if [ -x "$HOME/.bun/bin/bun" ]; then
    PATH="$HOME/.bun/bin:$PATH"
  else
    die "找不到 bun。装一个：curl -fsSL https://bun.sh/install | bash"
  fi
}

[ -f src/cli.ts ] || die "不在 sandbox-runtime 仓库根目录（缺 src/cli.ts）"
[ -f package.json ] || die "缺 package.json"

TARGETS="${TARGETS_ARG:-$DEFAULT_TARGETS}"
[ -n "${TARGETS// /}" ] || die "--targets 不能为空"

# ---- 版本号 --------------------------------------------------------------

CURRENT_VERSION="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' package.json | head -1)"
[ -n "$CURRENT_VERSION" ] || die "package.json 里读不到 version"

if [ -z "$VERSION_CODE" ]; then
  VERSION_CODE="$CURRENT_VERSION"
fi

case "$VERSION_CODE" in
  "$BASE_VERSION"|"$BASE_VERSION"-*) : ;;
  *)
    printf '\033[31m错误\033[0m 版本 %s 不在基线 %s 之下。\n' "$VERSION_CODE" "$BASE_VERSION" >&2
    printf '      ADK 的 SRTCompatibleVersion 只接受 %s 或 %s-<后缀>。\n' "$BASE_VERSION" "$BASE_VERSION" >&2
    printf '      确有必要换基线时用 --base %s。\n' "${VERSION_CODE%%-*}" >&2
    exit 1
    ;;
esac

SUFFIX="${VERSION_CODE#"$BASE_VERSION"}"
if [ -z "$SUFFIX" ]; then
  warn "版本 $VERSION_CODE 没有后缀，和上游未修改的 $BASE_VERSION 无法区分。"
  warn "上游没有 delegateDomainPolicy 字段，会静默忽略它，"
  warn "再因为 allowedDomains 为空把全部网络拒掉（fail-closed，但很难排查）。"
  warn "建议用 --version-code $BASE_VERSION-gov.1 之类再编。"
fi

# 版本号是 src/cli.ts 里静态 import 的 package.json 字段，编译时打进二进制，
# 运行时不再读外部文件。要改版本只能改文件再编，所以这里临时改写、退出时恢复。
PKG_BACKUP=""
restore_pkg() {
  if [ -n "$PKG_BACKUP" ] && [ -f "$PKG_BACKUP" ]; then
    mv -f "$PKG_BACKUP" package.json
    PKG_BACKUP=""
  fi
  return 0
}
trap restore_pkg EXIT INT TERM

if [ "$VERSION_CODE" != "$CURRENT_VERSION" ]; then
  PKG_BACKUP="$(mktemp "${TMPDIR:-/tmp}/srt-pkg.XXXXXX")"
  cp -p package.json "$PKG_BACKUP"
  STAMPED_VERSION="$VERSION_CODE" perl -0pi -e \
    's/("version"\s*:\s*")[^"]*(")/$1$ENV{STAMPED_VERSION}$2/' package.json
  note "临时改写 package.json: $CURRENT_VERSION → $VERSION_CODE（构建后恢复）"
fi

# ---- 溯源信息 ------------------------------------------------------------

printf '\n'
note "版本   $VERSION_CODE"
note "目标   $TARGETS"
note "bun    $(bun --version)"
if git rev-parse --git-dir >/dev/null 2>&1; then
  REV="$(git rev-parse --short HEAD)"
  DIRTY=""
  # package.json 刚被临时改过，把它排除掉，免得每次都报脏。
  if [ -n "$(git status --porcelain | grep -v '^ M package.json$' || true)" ]; then
    DIRTY=" (含未提交改动)"
  fi
  note "源码   $REV$DIRTY"
fi
printf '\n'

# ---- 编译 ----------------------------------------------------------------

mkdir -p "$DIST"

# 编译后不自动加载运行目录里的 .env / bunfig.toml / tsconfig.json / package.json。
# srt 是在 agent 的工作目录里启动的，缺了这些开关，工作区里放一个配置文件
# 就能影响 srt 自己的行为。
COMPILE_FLAGS=(
  --compile
  --no-compile-autoload-dotenv
  --no-compile-autoload-bunfig
  --no-compile-autoload-tsconfig
  --no-compile-autoload-package-json
)

for target in $TARGETS; do
  out="$DIST/srt-$target"
  rm -f "$out"
  note "→ $target"
  # 首次编某个架构会下载 Bun 运行时（约 37MB），之后走 ~/.bun 缓存。
  bun build src/cli.ts "${COMPILE_FLAGS[@]}" \
    --target="bun-$target" \
    --outfile "$out"
done

# ---- 产物 ----------------------------------------------------------------

printf '\n'
note "产物"
printf '%-22s %9s  %s\n' 文件 大小 类型
for target in $TARGETS; do
  out="$DIST/srt-$target"
  [ -f "$out" ] || die "$out 没有生成"
  size="$(human_size "$(file_size "$out")")"
  kind="$(file -b "$out" | cut -c1-56)"
  printf '%-22s %9s  %s\n' "srt-$target" "$size" "$kind"
done

# ---- 校验 ----------------------------------------------------------------

printf '\n'
note "本机架构自检"
host=""
case "$(uname -s)/$(uname -m)" in
  Darwin/arm64)   host="darwin-arm64" ;;
  Darwin/x86_64)  host="darwin-x64" ;;
  Linux/x86_64)   host="linux-x64" ;;
  Linux/aarch64)  host="linux-arm64" ;;
esac
native=""
for target in $TARGETS; do
  [ "$target" = "$host" ] && native="$DIST/srt-$target"
done

if [ -n "$native" ]; then
  got="$("$native" --version)"
  if [ "$got" = "$VERSION_CODE" ]; then
    printf '  %s --version → %s  ✓\n' "$(basename "$native")" "$got"
  else
    printf '\033[31m错误\033[0m %s --version 输出 %s，与期望的 %s 不一致。\n' \
      "$(basename "$native")" "$got" "$VERSION_CODE" >&2
    printf '      版本号是编译时静态导入打进二进制的，说明 package.json 没被正确改写。\n' >&2
    exit 1
  fi
else
  printf '  本机架构 %s 不在目标列表里，跳过实际执行\n' "${host:-未知}"
  printf '  Linux 产物请在容器里验：docker run --rm -v "$PWD/dist:/d:ro" --platform linux/arm64 ubuntu:24.04 /d/srt-linux-arm64 --version\n'
fi

printf '\n'
note "SHA256"
for target in $TARGETS; do
  out="$DIST/srt-$target"
  if command -v sha256sum >/dev/null 2>&1; then
    sum="$(sha256sum "$out" | cut -d' ' -f1)"
  else
    sum="$(shasum -a 256 "$out" | cut -d' ' -f1)"
  fi
  printf '  %s  %s\n' "$sum" "srt-$target"
done

if [ -n "$PKG_BACKUP" ]; then
  printf '\n'
  note "package.json 已恢复为 $CURRENT_VERSION"
fi
