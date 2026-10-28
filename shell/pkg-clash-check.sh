#!/bin/bash
# ============================================================================
# 本地 ipk 文件冲突预检
#
# 目的：opkg 遇到两个「不同包」声明同一文件路径会报 check_data_file_clashes
#       并让整次 make image 失败（约 4 分钟），报错还埋在几百行日志里。
#       这里在 make image 之前先算一遍，命中即立刻失败并指名道姓。
#
# 关键规则（此前两版都在这上面出过错）：
#   1. 只检查「真正会被安装的包」（包名出现在 PACKAGES 里）。
#      packages/ 里还堆着 store 带来的一堆未启用插件（passwall、xray-core、
#      advancedplus 等），它们之间互相重名与本固件无关，不能算冲突。
#   2. 同名包多版本只按「版本最高的那个」参与判定 —— opkg 对同一个包名
#      只会安装一个版本，绝不会同时装 0.11.1 和 27.299。
#   3. 同一个 ipk 内部重复列出同一路径（软链 + 实体）属正常，不算冲突。
#      所以先去重整行（包名+路径），再看路径是否被多条不同包名占用。
#
# 用法： bash shell/pkg-clash-check.sh <packages目录> "<PACKAGES 字符串>"
# 退出码：0 = 无冲突；1 = 有冲突或脚本无法完成检查
# ============================================================================
set -u

PKG_DIR="${1:-packages}"
shift || true
PKG_LIST="$*"

TAB=$(printf '\t')

# 工作目录放在 packages 同级，用相对路径：
# Windows 下 mktemp 会返回 `C:\...` 反斜杠路径，tar -C 对它处理不一致，
# 会造成内层解包静默失败。相对路径在 Linux / MSYS 下都稳定。
WORK="${PKG_DIR%/}/.clashcheck.$$"
rm -rf "$WORK"
mkdir -p "$WORK" || { echo "❌ 预检无法创建工作目录 $WORK"; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM

# ---------- 1. 归一化「会被安装的包名集合」 ----------
: > "$WORK/installed.txt"
for p in $PKG_LIST; do
    case "$p" in
        -*|'') continue ;;   # opkg 的减号排除项不是安装项
    esac
    echo "$p" >> "$WORK/installed.txt"
done
sort -u "$WORK/installed.txt" -o "$WORK/installed.txt"
INSTALLED_CNT=$(wc -l < "$WORK/installed.txt")

is_installed() { grep -qxF "$1" "$WORK/installed.txt"; }

# ---------- 2. 从 ipk 里取出 control ----------
read_control() {
    ipk="$1"; w="$2"
    mkdir -p "$w"
    rm -f "$w/control" "$w/control.tar.gz" "$w/control.tar.xz"
    for m in ./control.tar.gz control.tar.gz ./control.tar.xz control.tar.xz; do
        tar -xzf "$ipk" -C "$w" "$m" >/dev/null 2>&1 || continue
        base=$(basename "$m")
        [ -f "$w/$base" ] || continue
        for n in ./control control; do
            tar -xf "$w/$base" -C "$w" "$n" >/dev/null 2>&1 && break
        done
        [ -f "$w/control" ] && return 0
    done
    return 1
}

# ---------- 3. 收集 包名 / 版本 / 文件名 ----------
: > "$WORK/all.txt"
scanned=0
noctl=0
for pkg in "$PKG_DIR"/*.ipk; do
    [ -e "$pkg" ] || continue
    fname=$(basename "$pkg")
    scanned=$((scanned + 1))
    w="$WORK/ctl/$fname"
    if ! read_control "$pkg" "$w"; then
        echo "   ⚠️  读不出 control，跳过：$fname"
        noctl=$((noctl + 1))
        continue
    fi
    pname=$(sed -n 's/^Package:[[:space:]]*//p' "$w/control" | head -1)
    pver=$(sed -n 's/^Version:[[:space:]]*//p' "$w/control" | head -1)
    [ -n "$pname" ] || { noctl=$((noctl + 1)); continue; }
    is_installed "$pname" || continue
    printf '%s\t%s\t%s\n' "$pname" "${pver:--}" "$fname" >> "$WORK/all.txt"
done

if [ ! -s "$WORK/all.txt" ]; then
    echo "⚠️  预检：packages/ 里没有与 PACKAGES 对应的本地包（扫描 $scanned 个 ipk，control 读取失败 $noctl 个），跳过冲突检查。"
    exit 0
fi

# ---------- 4. 同名包只留版本最高的一个 ----------
# GNU sort -V 的版本序与 opkg 的 verrevcmp 在本项目涉及的版本号上一致
sort -t "$TAB" -k1,1 -k2,2V "$WORK/all.txt" > "$WORK/sorted.txt"
awk -F'\t' '{ last[$1] = $0 } END { for (k in last) print last[k] }' "$WORK/sorted.txt" \
    | sort > "$WORK/keep.txt"

# 被丢弃的多余版本，仅作提示
awk -F'\t' '{ cnt[$1]++; files[$1] = files[$1] " " $3 }
             END { for (k in cnt) if (cnt[k] > 1) printf "   ℹ️  %s 存在 %d 个版本，按最高版本安装：%s\n", k, cnt[k], files[k] }' \
    "$WORK/sorted.txt" | sort

KEEP_CNT=$(wc -l < "$WORK/keep.txt")

# ---------- 5. 展开每个保留包的 data.tar.gz 文件清单 ----------
: > "$WORK/index.txt"
for pkg in "$PKG_DIR"/*.ipk; do
    [ -e "$pkg" ] || continue
    fname=$(basename "$pkg")
    row=$(awk -F'\t' -v f="$fname" '$3 == f' "$WORK/keep.txt")
    [ -n "$row" ] || continue
    pname=$(printf '%s' "$row" | cut -f1)
    w="$WORK/data/$fname"
    mkdir -p "$w"
    ok=0
    for m in ./data.tar.gz data.tar.gz ./data.tar.xz data.tar.xz; do
        tar -xzf "$pkg" -C "$w" "$m" >/dev/null 2>&1 || continue
        base=$(basename "$m")
        [ -f "$w/$base" ] || continue
        tar -tf "$w/$base" 2>/dev/null \
            | grep -v '/$' | sed 's|^\./||' \
            | sed "s|^|${pname}${TAB}|" >> "$WORK/index.txt"
        ok=1
        break
    done
    [ "$ok" -eq 0 ] && echo "   ⚠️  读不出 data.tar.*，冲突判定可能不完整：$fname"
done

# ---------- 6. 判定：同一路径被「不同包」占用才算冲突 ----------
sort -u "$WORK/index.txt" > "$WORK/unique.txt"
clash=$(cut -f2 "$WORK/unique.txt" | sort | uniq -d)

if [ -n "$clash" ]; then
    echo "❌ 本地包之间存在文件路径冲突，make image 必定失败："
    echo "$clash" | while IFS= read -r f; do
        echo "   $f"
        awk -F'\t' -v p="$f" '$2 == p { print "       <- " $1 }' "$WORK/unique.txt"
    done
    echo ""
    echo "   处置方式（二选一）："
    echo "   · 两个包都必须装：把重叠文件内容合并后从其中一个包删掉（重打包 + 提版本号）"
    echo "   · 只需一个：从 PACKAGES / packages.txt 里去掉一个"
    exit 1
fi

echo "✅ 本地包冲突预检通过（扫描 $scanned 个 ipk；PACKAGES 命中 $INSTALLED_CNT 个包名，实际参与判定 $KEEP_CNT 个）"
exit 0
