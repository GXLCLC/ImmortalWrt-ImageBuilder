#!/bin/bash
# Log file for debugging
source shell/custom-packages.sh
source shell/switch_repository.sh
echo "第三方软件包: $CUSTOM_PACKAGES"
LOGFILE="/tmp/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >> $LOGFILE
echo "编译固件大小为: $PROFILE MB"
echo "Include Docker: $INCLUDE_DOCKER"

echo "Create pppoe-settings"
mkdir -p  /home/build/immortalwrt/files/etc/config

# 创建pppoe配置文件 yml传入环境变量ENABLE_PPPOE等 写入配置文件 供99-custom.sh读取
cat << EOF > /home/build/immortalwrt/files/etc/config/pppoe-settings
enable_pppoe=${ENABLE_PPPOE}
pppoe_account=${PPPOE_ACCOUNT}
pppoe_password=${PPPOE_PASSWORD}
EOF

echo "cat pppoe-settings"
cat /home/build/immortalwrt/files/etc/config/pppoe-settings

# ===== mwan3 默认配置清空 =====
# 上游 mwan3 包自带 /etc/config/mwan3，预置 wan/wan6/wanb/wanb6 四个接口、
# 10 个成员、5 个策略、3 条规则。其中 wan 为 enabled=1 且绑定 1.0.0.1 等跟踪 IP，
# 首启（尤其单网口/无外网）会显示"离线"，其余接口显示"已禁用"，容易被误认为固件故障。
# 本固件要求出厂为零接口、零策略，由用户按需在 LuCI 中自行创建。
# 注意：本文件与 pppoe-settings 同路径，workflow 已把 custom/ 挂到 files/etc/config，
# 因此写这里等价于写进随镜像发布的 FILES 覆盖层。
cat > /home/build/immortalwrt/files/etc/config/mwan3 <<'EOF'
# MultiWAN Manager 默认配置为空，请勿删除本文件。
# 需要多拨或多线路时，请在 LuCI「网络 → MultiWAN 管理器」中新建接口。
EOF
echo "✅ mwan3 默认配置已清空"

if [ -z "$CUSTOM_PACKAGES" ]; then
  echo "⚪️ 未选择 任何第三方软件包"
else
  # ============= 同步第三方插件库==============
  # 同步第三方软件仓库run/ipk
  echo "🔄 正在同步第三方软件仓库 Cloning run file repo..."
  git clone --depth=1 https://github.com/wukongdaily/store.git /tmp/store-run-repo

  # 拷贝 run/x86 下所有 run 文件和ipk文件 到 extra-packages 目录
  mkdir -p /home/build/immortalwrt/extra-packages
  cp -r /tmp/store-run-repo/run/x86/* /home/build/immortalwrt/extra-packages/

  echo "✅ Run files copied to extra-packages:"
  ls -lh /home/build/immortalwrt/extra-packages/*.run
  # 解压并拷贝ipk到packages目录
  sh shell/prepare-packages.sh
  ls -lah /home/build/immortalwrt/packages/
fi

# 输出调试信息
echo "$(date '+%Y-%m-%d %H:%M:%S') - 开始构建固件..."

# ============= imm仓库内的插件==============
# 定义所需安装的包列表 下列插件你都可以自行删减
PACKAGES=""
PACKAGES="$PACKAGES curl"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-argon-config-zh-cn"
#24.10
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"

# 文件管理器
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"
# ======== shell/custom-packages.sh =======
# 合并imm仓库以外的第三方插件
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"


# 判断是否需要编译 Docker 插件
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
    echo "Adding package: luci-i18n-dockerman-zh-cn"
fi

# 若构建openclash 则添加内核
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 已选择 luci-app-openclash，添加 openclash core"
    mkdir -p files/etc/openclash/core
    # Download clash_meta
    META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-v1.tar.gz"
    wget -qO- $META_URL | tar xOvz > files/etc/openclash/core/clash_meta
    chmod +x files/etc/openclash/core/clash_meta
    # Download GeoIP and GeoSite
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O files/etc/openclash/GeoIP.dat
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O files/etc/openclash/GeoSite.dat
    # Download latest openclash Client
    URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases/latest \
      | grep "browser_download_url.*ipk" \
      | head -n1 \
      | cut -d '"' -f 4)
    echo "OpenClash latest ipk: $URL"
    wget "$URL" -P /home/build/immortalwrt/packages/
else
    echo "⚪️ 未选择 luci-app-openclash"
fi

if echo "$PACKAGES" | grep -q "luci-app-ssr-plus"; then
    echo "✅ 已选择 luci-app-ssr-plus，添加 mihomo core"
    mkdir -p files/usr/bin
    # Download mihomo
    MIHOMO_URL="https://github.com/MetaCubeX/mihomo/releases/download/v1.19.24/mihomo-linux-amd64-compatible-v1.19.24.gz"
    mkdir -p files/usr/bin
    wget -qO- "$MIHOMO_URL" | gzip -dc > files/usr/bin/mihomo
    chmod +x files/usr/bin/mihomo
    echo "✅ 已下载 mihomo core"
    ls -lah files/usr/bin
else
    echo "⚪️ 未选择 luci-app-ssr-plus"
fi
# ===== 通用：带 SHA256 校验的 ipk 下载 =====
# 供 DDNSTO / EasyTier 等「固定版本、不引入第三方 feed」的场景复用
mkdir -p packages
fetch_ipk() {
    url="$1"; out="$2"; sha="$3"
    echo "⬇️  下载 $out"
    wget -q -O "$out" "$url" || { echo "❌ 下载失败: $url"; exit 1; }
    echo "${sha}  ${out}" | sha256sum -c - || { echo "❌ SHA256 校验失败: $out"; exit 1; }
}

# ===== DDNSTO 远程控制（预编译包，固定版本 + SHA256 校验）=====
# 来源: https://dl.openwrt.ai/packages-25.12/x86_64/kiddin9/
#   说明：24.10 目录里只到 3.0.4，4.2.2 只在 25.12 目录。
#   已核验 ddnstod 为静态链接 ELF x86-64（无 PT_INTERP），不依赖目标系统 musl 版本，
#   故 25.12 目录的包在 24.10 上可安全运行。
# 注意: 包内默认 enabled=0 且 token 为空，服务不会自启，需刷机后在 LuCI 填入 token 并启用
if [ "$INCLUDE_DDNSTO" = "yes" ]; then
    DDNSTO_BASE="https://dl.openwrt.ai/packages-25.12/x86_64/kiddin9"
    DDNSTO_PKG="ddnsto_4.2.2~8664-r3_all.ipk"
    DDNSTO_LUCI_PKG="luci-app-ddnsto_4.2.2-r1-r3_all.ipk"
    DDNSTO_SHA="8f0a6df1f2e110caa7d43eef3e26f5382665ee83bc46bad9e38117c3a9e7816c"
    DDNSTO_LUCI_SHA="7254a937bde2ff3edf806cd967c79e6a9a6dca51881e89dab0b1e585dd27e17b"

    fetch_ipk "$DDNSTO_BASE/$DDNSTO_PKG" "packages/$DDNSTO_PKG" "$DDNSTO_SHA"
    fetch_ipk "$DDNSTO_BASE/$DDNSTO_LUCI_PKG" "packages/$DDNSTO_LUCI_PKG" "$DDNSTO_LUCI_SHA"

    PACKAGES="$PACKAGES ddnsto luci-app-ddnsto"
    echo "✅ 已加入 DDNSTO 远程控制插件"
else
    echo "⚪️ 未集成 DDNSTO"
fi

# ===== EasyTier 升级到 2.7.0（含中文界面）=====
# 背景：wukongdaily/store 里只有 2.4.3，且中文语言文件被拆成独立的
#   luci-i18n-easytier-zh-cn 包，未随主包安装 → 界面显示英文。
#   2.7.0 的 luci-app-easytier 已内置 usr/lib/lua/luci/i18n/easytier.zh-cn.lmo，
#   装完即中文，无需额外语言包。
# 来源: https://dl.openwrt.ai/packages-25.12/x86_64/kiddin9/
# 已核验: easytier-core / easytier-cli / easytier-web 均为静态链接 ELF x86-64；
#   依赖 libc + kmod-tun，官方 24.10.6 的 kmods 源(6.6.133-r1) 及
#   luci-compat / luci-lua-runtime 均可满足。
if echo "$PACKAGES" | grep -q "luci-app-easytier"; then
    ET_BASE="https://dl.openwrt.ai/packages-25.12/x86_64/kiddin9"
    ET_PKG="easytier_2.7.0-r7_x86_64.ipk"
    ET_LUCI_PKG="luci-app-easytier_2.7.0-r15_all.ipk"
    ET_SHA="1a21f3d39143f5324bcceeb7423d5ec4a9ccd63017bd25ec8551ee38350487ea"
    ET_LUCI_SHA="19219ddf336f32f2c84b6a57c56a04a8a95dd164f250e6db087e6b831ad1a284"

    fetch_ipk "$ET_BASE/$ET_PKG" "packages/$ET_PKG" "$ET_SHA"
    fetch_ipk "$ET_BASE/$ET_LUCI_PKG" "packages/$ET_LUCI_PKG" "$ET_LUCI_SHA"

    # store 里 2.4.3 的 ipk 会被 prepare-packages.sh 一并解到 packages/，
    # 这里清掉旧版本与独立语言包，保证同目录只有一份、构建结果确定。
    find packages -maxdepth 1 -name 'easytier_*.ipk' ! -name "$ET_PKG" -delete 2>/dev/null
    find packages -maxdepth 1 -name 'luci-app-easytier_*.ipk' ! -name "$ET_LUCI_PKG" -delete 2>/dev/null
    find packages -maxdepth 1 -name 'luci-i18n-easytier-zh-cn_*.ipk' -delete 2>/dev/null

    echo "✅ EasyTier 已升级至 2.7.0（luci 前端 2.7.0-r15，内置简体中文）"
    ls -lah packages/ | grep -i easytier
else
    echo "⚪️ 未选择 luci-app-easytier"
fi

# 构建镜像
echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image with the following packages:"
echo "$PACKAGES"

make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files" ROOTFS_PARTSIZE=$PROFILE

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."
