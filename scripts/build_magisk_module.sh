#!/bin/sh
# 打包 Komari Agent 的 Magisk 模块 zip。
#
# 用法:
#   scripts/build_magisk_module.sh <agent-binary> <version> [output-zip]
#
# 参数:
#   agent-binary  已构建的 aarch64-linux-musl 静态二进制
#   version       写入 module.prop 的版本号（如 v0.1.6 或 dev）
#   output-zip    输出路径，默认 dist/komari-agent-magisk-module-arm64.zip
#
# 产物结构（zip 根目录即模块目录，符合 Magisk 模块规范）:
#   module.prop
#   install.sh
#   service.sh
#   uninstall.sh
#   README.md
#   komari-agent
set -eu

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: $0 <agent-binary> <version> [output-zip]" >&2
  exit 1
fi

agent_bin="$1"
version="$2"
output_zip="${3:-dist/komari-agent-magisk-module-arm64.zip}"

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
module_src="$repo_root/magisk"

# 输出路径统一转成绝对路径：打包时会在 stage 子目录里执行 zip，
# 相对路径会相对 stage 解析，导致写入失败或写错位置。
case "$output_zip" in
  /*) ;;
  *) output_zip="$repo_root/$output_zip" ;;
esac

if [ ! -f "$agent_bin" ]; then
  echo "error: agent binary not found: $agent_bin" >&2
  exit 1
fi
if [ ! -d "$module_src" ]; then
  echo "error: module source dir not found: $module_src" >&2
  exit 1
fi

# --- 校验二进制是 aarch64 静态 ELF ---
if command -v file >/dev/null 2>&1; then
  file_out="$(file -b "$agent_bin")"
  case "$file_out" in
    *"ELF 64-bit"*"ARM aarch64"*) ;;
    *)
      echo "error: not an aarch64 ELF: $file_out" >&2
      exit 1
      ;;
  esac
  case "$file_out" in
    *"statically linked"*|*"static-pie"*) ;;
    *)
      echo "error: agent binary is not statically linked: $file_out" >&2
      exit 1
      ;;
  esac
fi

# --- 由版本号推导 versionCode（Magisk 用于比较新旧）---
# v0.1.6 -> 106 ; 0.1.6 -> 106 ; dev -> 1
version_code=1
case "$version" in
  v[0-9]*.[0-9]*.[0-9]*|[0-9]*.[0-9]*.[0-9]*)
    vc_input="${version#v}"
    major="${vc_input%%.*}"
    rest="${vc_input#*.}"
    minor="${rest%%.*}"
    patch="${rest#*.}"
    case "$major$minor$patch" in
      *[!0-9]*)
        version_code=1
        ;;
      *)
        version_code=$((major * 10000 + minor * 100 + patch))
        [ "$version_code" -gt 0 ] || version_code=1
        ;;
    esac
    ;;
  *) version_code=1 ;;
esac

# --- 组装临时目录 ---
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/komari-magisk.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM

stage="$work_dir/module"
mkdir -p "$stage"

for f in module.prop install.sh service.sh uninstall.sh README.md; do
  if [ ! -f "$module_src/$f" ]; then
    echo "error: missing module file: $module_src/$f" >&2
    exit 1
  fi
  cp "$module_src/$f" "$stage/$f"
done

# module.prop 版本占位替换
sed -e "s|__VERSION__|$version|g" \
    -e "s|__VERSION_CODE__|$version_code|g" \
    "$module_src/module.prop" > "$stage/module.prop"

# 脚本执行位（zip 会保留 unix mode）
chmod 0755 "$stage/install.sh" "$stage/service.sh" "$stage/uninstall.sh"
chmod 0644 "$stage/module.prop" "$stage/README.md"

# agent 二进制放在模块根，install.sh 会把它复制到 /data/adb/komari-agent/bin/
cp "$agent_bin" "$stage/komari-agent"
chmod 0755 "$stage/komari-agent"

# --- 结构自检（打包前）---
for f in module.prop install.sh service.sh uninstall.sh komari-agent; do
  [ -f "$stage/$f" ] || { echo "error: staged file missing: $f" >&2; exit 1; }
done
if grep -q '__VERSION__\|__VERSION_CODE__' "$stage/module.prop"; then
  echo "error: module.prop still contains placeholders" >&2
  exit 1
fi
if ! grep -q "^id=komari_agent$" "$stage/module.prop"; then
  echo "error: module.prop id is not komari_agent" >&2
  exit 1
fi

# --- 打包 ---
mkdir -p "$(dirname "$output_zip")"
rm -f "$output_zip"
(
  cd "$stage"
  # -X 去掉多余属性，保证可复现；按名排序让产物稳定
  find . -type f | LC_ALL=C sort | sed 's|^\./||' > "$work_dir/filelist"
  zip -X -q "$output_zip" -@ < "$work_dir/filelist"
)

# --- 结构自检（打包后）---
if command -v unzip >/dev/null 2>&1; then
  listing="$(unzip -Z1 "$output_zip")"
  for f in module.prop install.sh service.sh uninstall.sh komari-agent; do
    printf '%s\n' "$listing" | grep -qx "$f" || {
      echo "error: zip missing root entry: $f" >&2
      exit 1
    }
  done
  # 不允许有顶层目录包裹（Magisk 要求文件在 zip 根）
  if printf '%s\n' "$listing" | grep -q '^[^/]*/'; then
    echo "error: zip contains nested directories; Magisk requires flat root" >&2
    exit 1
  fi
  # 脚本必须保留执行位
  for f in install.sh service.sh uninstall.sh; do
    mode="$(unzip -Z "$output_zip" "$f" | awk 'NR==1 {print $1}')"
    case "$mode" in
      -rwxr-xr-x|-rwxr-xr-x*) ;;
      *)
        echo "error: $f lost executable bit in zip (mode=$mode)" >&2
        exit 1
        ;;
    esac
  done
fi

size="$(wc -c < "$output_zip" | tr -d ' ')"
echo "built: $output_zip (${size} bytes, version=$version, versionCode=$version_code)"
