#!/bin/bash
set -e

# 检查 jq 是否已安装
if ! command -v jq >/dev/null 2>&1; then
    echo "未检测到 jq，正在尝试安装..."
    if command -v apt >/dev/null 2>&1; then
        apt update && apt install -y jq
    elif command -v apk >/dev/null 2>&1; then
        apk add jq
    elif command -v yum >/dev/null 2>&1; then
        yum install -y jq
    else
        echo "无法自动安装 jq，请手动安装后重试。"
        exit 1
    fi
fi

# 1. 检测架构
arch=$(uname -m)
case "$arch" in
    x86_64)
        xray_file="Xray-linux-64.zip"
        ;;
    aarch64)
        xray_file="Xray-linux-arm64-v8a.zip"
        ;;
    armv7l)
        xray_file="Xray-linux-arm32-v7a.zip"
        ;;
    armv6l)
        xray_file="Xray-linux-arm32-v6.zip"
        ;;
    *)
        echo "不支持的架构: $arch"
        exit 1
        ;;
esac

# 2. 获取当前版本
if ! command -v xray &>/dev/null; then
    echo "未安装 Xray 或未在 PATH 中找到。"
    exit 1
fi
current_version=$(/usr/local/bin/xray -version 2>/dev/null | grep 'Xray' | head -n1 | awk '{print $2}')

# 3. 获取最新版本信息
release_info=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest)
download_url=$(echo "$release_info" | jq -r ".assets[] | select(.name==\"$xray_file\") | .browser_download_url")
latest_version=$(echo "$release_info" | jq -r ".tag_name")

if [[ -z "$download_url" ]]; then
    echo "无法获取对应架构 [$arch] 的下载地址。"
    exit 1
fi

# 4. 版本对比
clean_current_version=$(echo "$current_version" | sed 's/^v//')
clean_latest_version=$(echo "$latest_version" | sed 's/^v//')

echo "当前版本：$clean_current_version"
echo "最新版本：$clean_latest_version"

if [[ "$clean_current_version" == "$clean_latest_version" ]]; then
    echo "Xray 已是最新版本，无需更新。"
    exit 0
fi

# 5. 下载并解压
echo "开始下载：$download_url"
wget -O /tmp/$xray_file "$download_url"
unzip -o /tmp/$xray_file -d /tmp/xray-update

# 6. 停止服务并备份旧核心
systemctl stop xray
cp /usr/local/bin/xray /usr/local/bin/xray.bak.$(date +%F_%T)

# 7. 替换并重启
mv /tmp/xray-update/xray /usr/local/bin/xray
chmod +x /usr/local/bin/xray
systemctl start xray

# 8. 清理
rm -rf /tmp/$xray_file /tmp/xray-update
find /usr/local/bin -name 'xray.bak.*' -type f -mtime +7 -exec rm -f {} \;

echo "✅ Xray 已成功从版本 $current_version 更新至 $latest_version 并完成重启。"
