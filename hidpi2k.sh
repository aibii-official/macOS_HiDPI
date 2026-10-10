#!/bin/bash
# =============================================================================
# hidpi2k.sh — 通用 HiDPI 注入工具（无需安装任何 App / 驱动，完全可逆）
#
# 原理：macOS 会按「厂商ID + 产品ID」读取
#   /Library/Displays/Contents/Resources/Overrides/DisplayVendorID-XXXX/DisplayProductID-YYYY
# 中的 scale-resolutions 列表，把其中带 HiDPI 标志的分辨率当作显示器原生支持
# 的模式。本脚本自动枚举当前连接的显示器，为「需要注入的外接屏」生成该配置，
# 并打开 WindowServer 的 DisplayResolutionEnabled 开关。
#
# 自动跳过：
#   1. 本机内置屏（Built-In / Color LCD）
#   2. 原生横向分辨率 >= 3840 的屏（4K/5K/6K 原生就支持 HiDPI）
# 可用 --force 强制覆盖以上两条规则。
#
# 用法：
#   ./hidpi2k.sh list                列出所有显示器及判定结果
#   ./hidpi2k.sh install [--all]     为可注入的屏注入 HiDPI（多台时交互选择；--all 全部）
#   ./hidpi2k.sh uninstall [--all]   移除注入（完全还原）
#   ./hidpi2k.sh status              总览：SIP / WindowServer 开关 / 已注入列表
#   通用选项：--force 强制处理被跳过的屏
#
# 安装/卸载会自动用 sudo 提权（需输入一次开机密码）；改动需注销或重启后生效。
# =============================================================================

set -euo pipefail

OVERRIDE_ROOT="/Library/Displays/Contents/Resources/Overrides"
WS_DOMAIN="/Library/Preferences/com.apple.windowserver"
WS_KEY="DisplayResolutionEnabled"
MARKER_KEY="HIDPI2KInjected"

# HiDPI 逻辑分辨率档位（实际渲染 = 2 倍后缩小，覆盖 1080p/2K/4K 屏常用档）
HIDPI_MODES=(1280x720 1440x810 1600x900 1920x1080 2048x1152 2240x1260)
# 附带注入的普通（非 HiDPI）档位；后半部分是各 HiDPI 档的渲染分辨率，
# 作为"垫底模式"帮助系统校验通过
NORMAL_MODES=(2560x1440 1920x1080 1600x900 1280x720 2880x1620 3200x1800 3840x2160 4096x2304 4480x2520)
# 原生宽度达到该值即视为「原生支持 HiDPI」
NATIVE_HIDPI_MIN_WIDTH=3840

SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

FORCE=0
ALL=0
SUBCMD=""
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        --all)   ALL=1 ;;
        list|install|uninstall|status) SUBCMD="$arg" ;;
        -h|--help) SUBCMD="help" ;;
        *) echo "未知参数: $arg"; SUBCMD="help" ;;
    esac
done

usage() {
    sed -n '2,33p' "$SCRIPT_PATH" | sed 's/^# \{0,1\}//'
}

# -----------------------------------------------------------------------------
# 枚举显示器：输出 TSV —— vid(hex)  pid(hex)  name  width  height  builtin(yes/no)
# -----------------------------------------------------------------------------
enumerate_displays() {
    system_profiler -json SPDisplaysDataType 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for gpu in data.get("SPDisplaysDataType", []):
    for mon in gpu.get("spdisplays_ndrvs", []):
        vid = (mon.get("_spdisplays_display-vendor-id") or "").lower()
        pid = (mon.get("_spdisplays_display-product-id") or "").lower()
        name = mon.get("_name") or "未知显示器"
        builtin = "yes" if mon.get("spdisplays_builtin") == "spdisplays_yes" else "no"
        # 部分机型内置屏不带 builtin 键，用名字兜底（Apple 笔记本内置屏多叫 Color LCD / Built-in）
        lname = name.lower()
        if "built-in" in lname or "color lcd" in lname:
            builtin = "yes"
        w = h = 0
        pixels = mon.get("_spdisplays_pixels") or ""
        try:
            parts = pixels.replace("×", " x ").split(" x ")
            w, h = int(parts[0]), int(parts[1])
        except Exception:
            pass
        print("\t".join([vid, pid, name, str(w), str(h), builtin]))
'
}

# 判定单台显示器：输出「分类|原因」。分类：eligible / skip
classify() {  # vid pid name width height builtin
    local vid="$1" pid="$2" name="$3" w="$4" h="$5" builtin="$6"
    if [ "$FORCE" = "1" ]; then echo "eligible|--force 强制"; return; fi
    if [ "$builtin" = "yes" ]; then echo "skip|内置屏"; return; fi
    if [ -z "$vid" ] || [ -z "$pid" ]; then echo "skip|无法读取厂商/产品ID（可能是 DisplayLink 类扩展坞）"; return; fi
    if [ "$w" -ge "$NATIVE_HIDPI_MIN_WIDTH" ]; then echo "skip|原生 ${w}x${h}，已原生支持 HiDPI"; return; fi
    echo "eligible|外接 ${w}x${h}，无原生 HiDPI"
}

override_file() { # vid pid
    echo "$OVERRIDE_ROOT/DisplayVendorID-$1/DisplayProductID-$2"
}

is_injected() { # vid pid
    local f; f="$(override_file "$1" "$2")"
    [ -f "$f" ] && plutil -extract "$MARKER_KEY" raw "$f" 2>/dev/null | grep -q true
}

# -----------------------------------------------------------------------------
# 分辨率数据编码（与 macOS 27 系统自带 override 格式一致）
#   普通档：  <宽><高><00000001>                       12 字节
#   HiDPI-A： <宽*2><高*2><00000001><00200000>          16 字节
#   HiDPI-B： <宽*2><高*2><00000009><00a00000>          16 字节（"更多空间"档）
# -----------------------------------------------------------------------------
hex_to_b64() { printf '%s' "$1" | xxd -r -p | base64; }
entry_normal()   { hex_to_b64 "$(printf '%08x%08x00000001' "$1" "$2")"; }
entry_hidpi_a()  { hex_to_b64 "$(printf '%08x%08x0000000100200000' $(($1*2)) $(($2*2)))"; }
entry_hidpi_b()  { hex_to_b64 "$(printf '%08x%08x0000000900a00000' $(($1*2)) $(($2*2)))"; }

xml_escape() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

# 生成 override plist 到 stdout 指定路径
generate_plist() { # vid(hex) pid(hex) name outpath
    local vid="$1" pid="$2" name="$3" out="$4"
    local vid_dec=$((16#$vid)) pid_dec=$((16#$pid))
    local tmp; tmp="$(mktemp -t hidpi2k)"
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
        echo '<plist version="1.0">'
        echo '<dict>'
        echo "    <key>DisplayProductID</key>"
        echo "    <integer>$pid_dec</integer>"
        echo "    <key>DisplayVendorID</key>"
        echo "    <integer>$vid_dec</integer>"
        echo "    <key>DisplayProductName</key>"
        echo "    <string>$(xml_escape "$name")</string>"
        echo "    <key>$MARKER_KEY</key>"
        echo "    <true/>"
        echo "    <key>scale-resolutions</key>"
        echo "    <array>"
        local m w h
        for m in "${HIDPI_MODES[@]}"; do w="${m%x*}"; h="${m#*x}"
            echo "        <data>$(entry_hidpi_a "$w" "$h")</data>"; done
        for m in "${HIDPI_MODES[@]}"; do w="${m%x*}"; h="${m#*x}"
            echo "        <data>$(entry_hidpi_b "$w" "$h")</data>"; done
        for m in "${NORMAL_MODES[@]}"; do w="${m%x*}"; h="${m#*x}"
            echo "        <data>$(entry_normal "$w" "$h")</data>"; done
        echo "    </array>"
        echo '</dict>'
        echo '</plist>'
    } > "$tmp"
    if ! plutil -lint "$tmp" >/dev/null 2>&1; then
        echo "错误：生成的 plist 校验失败" >&2; rm -f "$tmp"; return 1
    fi
    # 转成二进制格式，与 /System 下苹果自带的 override 保持一致
    plutil -convert binary1 "$tmp"
    mv "$tmp" "$out"
}

# -----------------------------------------------------------------------------
# 提权：install/uninstall 需要 root
# -----------------------------------------------------------------------------
ensure_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        echo "需要管理员权限，请输入开机密码："
        exec sudo "$SCRIPT_PATH" "$@"
    fi
}

# 无终端环境下无法进行交互提示
require_tty() {
    if [ ! -w /dev/tty ]; then
        echo "错误：当前环境无法交互（无终端），请改用 --all 参数。" >&2
        exit 1
    fi
}

# 从可注入列表中让用户选择（单台直接返回；--all 全选；否则交互）
select_targets() { # 输入: 每行 vid pid name；输出选中行
    local lines=("$@")
    if [ "${#lines[@]}" -eq 1 ] || [ "$ALL" = "1" ]; then
        printf '%s\n' "${lines[@]}"; return
    fi
    require_tty
    echo "检测到多台可注入的显示器：" > /dev/tty
    local i=1
    for l in "${lines[@]}"; do
        echo "  [$i] $(echo "$l" | cut -f3)  (VID:$(echo "$l" | cut -f1) PID:$(echo "$l" | cut -f2))" > /dev/tty
        i=$((i+1))
    done
    printf "请输入序号（可用逗号分隔，或输入 a 全选）: " > /dev/tty
    local ans; read -r ans < /dev/tty
    if [ "$ans" = "a" ] || [ "$ans" = "A" ]; then printf '%s\n' "${lines[@]}"; return; fi
    local n
    echo "$ans" | tr ',' ' ' | while read -r n; do
        case "$n" in ''|*[!0-9]*) continue ;; esac
        [ "$n" -ge 1 ] && [ "$n" -le "${#lines[@]}" ] && printf '%s\n' "${lines[$((n-1))]}"
    done
}

# -----------------------------------------------------------------------------
cmd_list() {
    echo "正在枚举显示器……"
    local found=0
    while IFS=$'\t' read -r vid pid name w h builtin; do
        [ -z "${vid}${pid}${name}" ] && continue
        found=1
        local cls reason; IFS='|' read -r cls reason <<< "$(classify "$vid" "$pid" "$name" "$w" "$h" "$builtin")"
        local mark=""
        if [ "$cls" = "eligible" ]; then
            if [ -n "$vid" ] && is_injected "$vid" "$pid"; then mark="【已注入】"; else mark="【未注入】"; fi
        fi
        local verdict
        if [ "$cls" = "eligible" ]; then verdict="可注入 $mark"; else verdict="跳过（${reason}）"; fi
        printf '  %-20s VID:%-6s PID:%-6s 原生:%sx%s  %s\n' "$name" "${vid:-?}" "${pid:-?}" "$w" "$h" "$verdict"
    done <<< "$(enumerate_displays)"
    if [ "$found" = "0" ]; then echo "  未发现任何显示器。"; fi
}

cmd_status() {
    echo "===== 系统状态 ====="
    echo "  SIP: $(csrutil status 2>/dev/null | sed 's/.*: //')"
    local ws; ws="$(defaults read "$WS_DOMAIN" "$WS_KEY" 2>/dev/null || echo '未设置')"
    echo "  WindowServer $WS_KEY: $ws"
    echo "  注入目录: $OVERRIDE_ROOT"
    if [ -d "$OVERRIDE_ROOT" ]; then
        local any=0
        while IFS= read -r f; do
            if plutil -extract "$MARKER_KEY" raw "$f" 2>/dev/null | grep -q true; then
                any=1
                echo "    [本脚本注入] ${f#$OVERRIDE_ROOT/}"
            else
                echo "    [其他来源]   ${f#$OVERRIDE_ROOT/}"
            fi
        done <<< "$(find "$OVERRIDE_ROOT" -name 'DisplayProductID-*' ! -name '*.bak.*' -type f 2>/dev/null)"
        if [ "$any" = "0" ]; then echo "    （无本脚本注入的配置）"; fi
    else
        echo "    （目录不存在，尚未注入）"
    fi
    echo ""
    echo "===== 显示器 ====="
    cmd_list
}

cmd_install() {
    ensure_root "$@"
    echo "正在枚举显示器……"
    local eligible=() skipped=0
    while IFS=$'\t' read -r vid pid name w h builtin; do
        [ -z "${vid}${pid}${name}" ] && continue
        local cls reason; IFS='|' read -r cls reason <<< "$(classify "$vid" "$pid" "$name" "$w" "$h" "$builtin")"
        if [ "$cls" = "eligible" ]; then
            eligible+=("$vid"$'\t'"$pid"$'\t'"$name")
        else
            skipped=$((skipped+1)); echo "  跳过：${name}（${reason}）"
        fi
    done <<< "$(enumerate_displays)"

    if [ "${#eligible[@]}" -eq 0 ]; then
        echo "没有需要注入的显示器（内置屏与原生 HiDPI 屏已自动跳过；可用 --force 强制）。"
        exit 0
    fi

    local targets=()
    while IFS= read -r line; do [ -n "$line" ] && targets+=("$line"); done <<< "$(select_targets "${eligible[@]}")"
    [ "${#targets[@]}" -eq 0 ] && { echo "未选择任何显示器，已取消。"; exit 0; }

    for t in "${targets[@]}"; do
        local vid pid name
        vid="$(echo "$t" | cut -f1)"; pid="$(echo "$t" | cut -f2)"; name="$(echo "$t" | cut -f3)"
        local dir="$OVERRIDE_ROOT/DisplayVendorID-$vid"
        local file="$dir/DisplayProductID-$pid"
        echo "正在为「${name}」(VID:${vid} PID:${pid}) 生成 HiDPI 配置……"
        local tmp; tmp="$(mktemp -t hidpi2k-plist)"
        generate_plist "$vid" "$pid" "$name" "$tmp"
        mkdir -p "$dir"
        [ -f "$file" ] && cp "$file" "$file.bak.$(date +%Y%m%d%H%M%S)"
        cp "$tmp" "$file"; rm -f "$tmp"
        chown root:wheel "$file"; chmod 644 "$file"
        echo "  已写入 $file"
    done

    defaults write "$WS_DOMAIN" "$WS_KEY" -bool YES
    echo "已开启 WindowServer ${WS_KEY}。"
    echo ""
    echo "完成！请注销或重启后，到「系统设置 → 显示器」按住 Option 点「缩放」"
    echo "（或勾选「显示所有分辨率」），即可看到并选择带（HiDPI）标志的档位，"
    echo "2K 屏推荐选择 2048x1152（HiDPI）。"
}

cmd_uninstall() {
    ensure_root "$@"
    if [ ! -d "$OVERRIDE_ROOT" ]; then echo "没有任何注入，无需卸载。"; exit 0; fi
    local mine=()
    while IFS= read -r f; do
        if plutil -extract "$MARKER_KEY" raw "$f" 2>/dev/null | grep -q true; then mine+=("$f"); fi
    done <<< "$(find "$OVERRIDE_ROOT" -name 'DisplayProductID-*' ! -name '*.bak.*' -type f 2>/dev/null)"
    if [ "${#mine[@]}" -eq 0 ]; then echo "没有本脚本注入的配置，无需卸载。"; exit 0; fi

    local targets=()
    if [ "$ALL" = "1" ] || [ "${#mine[@]}" -eq 1 ]; then
        targets=("${mine[@]}")
    else
        require_tty
        echo "发现 ${#mine[@]} 份本脚本注入的配置：" > /dev/tty
        local i=1; for f in "${mine[@]}"; do echo "  [$i] ${f#$OVERRIDE_ROOT/}" > /dev/tty; i=$((i+1)); done
        printf "请输入要移除的序号（逗号分隔，或 a 全部）: " > /dev/tty
        local ans; read -r ans < /dev/tty
        if [ "$ans" = "a" ] || [ "$ans" = "A" ]; then targets=("${mine[@]}"); else
            local n
            while read -r n; do
                case "$n" in ''|*[!0-9]*) continue ;; esac
                [ "$n" -ge 1 ] && [ "$n" -le "${#mine[@]}" ] && targets+=("${mine[$((n-1))]}")
            done <<< "$(echo "$ans" | tr ',' '\n')"
        fi
    fi
    [ "${#targets[@]}" -eq 0 ] && { echo "未选择，已取消。"; exit 0; }

    for f in "${targets[@]}"; do
        rm -f "$f"; echo "  已删除 ${f#$OVERRIDE_ROOT/}"
    done
    # 清理本脚本重复安装时留下的带标记 .bak 备份
    while IFS= read -r f; do
        if plutil -extract "$MARKER_KEY" raw "$f" 2>/dev/null | grep -q true; then rm -f "$f"; fi
    done <<< "$(find "$OVERRIDE_ROOT" -name '*.bak.*' -type f 2>/dev/null)"
    # 清理可能由本脚本创建的空目录链（rmdir 只在为空时生效，安全）
    for f in "${targets[@]}"; do rmdir "$(dirname "$f")" 2>/dev/null || true; done
    # 清理可能由本脚本创建的空目录链（rmdir 只在为空时生效，安全）
    rmdir "$OVERRIDE_ROOT" 2>/dev/null || true
    rmdir "$(dirname "$OVERRIDE_ROOT")" 2>/dev/null || true
    rmdir "$(dirname "$(dirname "$OVERRIDE_ROOT")")" 2>/dev/null || true
    rmdir "/Library/Displays" 2>/dev/null || true

    # 若已无任何注入，还原 WindowServer 开关
    if ! find "$OVERRIDE_ROOT" -name 'DisplayProductID-*' ! -name '*.bak.*' -type f 2>/dev/null | grep -q .; then
        defaults delete "$WS_DOMAIN" "$WS_KEY" 2>/dev/null || true
        echo "已还原 WindowServer ${WS_KEY}。"
    fi
    echo ""
    echo "卸载完成（注销或重启后完全还原）。"
}

case "${SUBCMD:-help}" in
    list)      cmd_list ;;
    status)    cmd_status ;;
    install)   cmd_install "$@" ;;
    uninstall) cmd_uninstall "$@" ;;
    *)         usage ;;
esac
