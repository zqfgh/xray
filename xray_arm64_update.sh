#!/bin/bash
set -e

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
LOG_FILE="/var/log/xray_update.log"

# 检测 Xray 路径
X_RAY_BIN=$(command -v xray)
if [ -z "$X_RAY_BIN" ]; then
    for try_path in /usr/bin/xray /usr/local/bin/xray /usr/local/sbin/xray; do
        if [ -x "$try_path" ]; then
            X_RAY_BIN="$try_path"
            break
        fi
    done
fi

if [ -z "$X_RAY_BIN" ]; then
    echo "❌ Xray executable not found. Please install Xray first." | tee -a "$LOG_FILE"
    exit 1
fi

BACKUP_DIR=$(dirname "$X_RAY_BIN")

# 测试是否可以直连 GitHub
if curl --connect-timeout 5 -s https://github.com > /dev/null 2>&1; then
    echo "🌐 GitHub is directly accessible. Proceeding without proxy." | tee -a "$LOG_FILE"
		#unset http_proxy
		#unset https_proxy
else
    echo "⚠️ GitHub not reachable directly. Enabling proxy" | tee -a "$LOG_FILE"
    export http_proxy="http://127.0.0.1:7890"
    export https_proxy="http://127.0.0.1:7890"
fi

echo "$(date) Starting Xray update task..." | tee -a "$LOG_FILE"

# 检查 jq 是否已安装
if ! command -v jq >/dev/null 2>&1; then
    echo "📦 jq not found. Attempting to install..." | tee -a "$LOG_FILE"
    if command -v apt >/dev/null 2>&1; then
        apt update && apt install -y jq
    elif command -v apk >/dev/null 2>&1; then
        apk add jq
    elif command -v yum >/dev/null 2>&1; then
        yum install -y jq
    else
        echo "❌ Cannot install jq automatically. Please install it manually." | tee -a "$LOG_FILE"
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
        echo "❌ Unsupported architecture: $arch" | tee -a "$LOG_FILE"
        exit 1
        ;;
esac

# 2. 获取当前版本
if [ ! -x "$X_RAY_BIN" ]; then
    echo "❌ Detected Xray binary is not executable: $X_RAY_BIN" | tee -a "$LOG_FILE"
    exit 1
fi
current_version=$("$X_RAY_BIN" -version 2>/dev/null | grep 'Xray' | head -n1 | awk '{print $2}')
#测试脚本能否正常使用
#current_version="25.5.15"
echo "🔍 Current version: $current_version" | tee -a "$LOG_FILE"

# 3. 获取最新版本信息
release_info=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest)
download_url=$(echo "$release_info" | jq -r ".assets[] | select(.name==\"$xray_file\") | .browser_download_url")
latest_version=$(echo "$release_info" | jq -r ".tag_name")

if [[ -z "$download_url" || "$download_url" == "null" ]]; then
    echo "❌ Cannot find download URL for [$arch] architecture." | tee -a "$LOG_FILE"
    exit 1
fi

echo "📌 Latest version: $latest_version" | tee -a "$LOG_FILE"

clean_current_version=$(echo "$current_version" | sed 's/^v//')
clean_latest_version=$(echo "$latest_version" | sed 's/^v//')

# 4. 版本对比
if [[ "$clean_current_version" == "$clean_latest_version" ]]; then
    echo "✅ Xray is already up to date." | tee -a "$LOG_FILE"
    exit 0
fi

echo "⬇️ Downloading new version..." | tee -a "$LOG_FILE"
tmp_dir=$(mktemp -d)
wget -O "$tmp_dir/$xray_file" "$download_url"

echo "📦 Extracting files..." | tee -a "$LOG_FILE"
unzip -o "$tmp_dir/$xray_file" -d "$tmp_dir/xray-update"

# 5. 停止 Xray 服务，支持 systemd 或 OpenWrt init.d
echo "🛑 Stopping Xray service..." | tee -a "$LOG_FILE"
if command -v systemctl >/dev/null 2>&1; then
    systemctl stop xray
else
    /etc/init.d/xray stop || true
fi

# 6. 备份旧版本，只保留最近一次备份
echo "🗂️ Backing up current version..." | tee -a "$LOG_FILE"
backup_file="${BACKUP_DIR}/xray.bak"
if [ -f "$backup_file" ]; then
    rm -f "$backup_file"
fi
cp "$X_RAY_BIN" "$backup_file"

# 7. 替换 Xray 并赋权
echo "🔧 Replacing Xray binary..." | tee -a "$LOG_FILE"
mv "$tmp_dir/xray-update/xray" "$X_RAY_BIN"
chmod +x "$X_RAY_BIN"

# 8. 启动 Xray 服务
echo "🚀 Starting Xray service..." | tee -a "$LOG_FILE"
if command -v systemctl >/dev/null 2>&1; then
    systemctl start xray
else
    /etc/init.d/xray start || true
fi

# 9. 清理临时文件
echo "🧹 Cleaning up..." | tee -a "$LOG_FILE"
rm -rf "$tmp_dir"

echo "✅ Xray successfully updated from version $current_version to $latest_version." | tee -a "$LOG_FILE"
