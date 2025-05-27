#!/bin/bash
set -e

# 设置 HTTP 代理（如需取消，注释掉下面两行）
export http_proxy="http://127.0.0.1:7890"
export https_proxy="http://127.0.0.1:7890"
#取消代理
#unset https_proxy
#unset https_proxy
#查看代理状态
#env | grep -i proxy

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
LOG_FILE="/var/log/xray_update.log"
BACKUP_DIR="/usr/bin"
X_RAY_BIN="${BACKUP_DIR}/xray"

echo "$(date) 开始执行 Xray 更新任务" | tee -a "$LOG_FILE"

# 检查 jq 是否已安装
if ! command -v jq >/dev/null 2>&1; then
    echo "未检测到 jq，正在尝试安装..." | tee -a "$LOG_FILE"
    if command -v apt >/dev/null 2>&1; then
        apt update && apt install -y jq
    elif command -v apk >/dev/null 2>&1; then
        apk add jq
    elif command -v yum >/dev/null 2>&1; then
        yum install -y jq
    else
        echo "无法自动安装 jq，请手动安装后重试。" | tee -a "$LOG_FILE"
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
        echo "不支持的架构: $arch" | tee -a "$LOG_FILE"
        exit 1
        ;;
esac

# 2. 获取当前版本
if [ ! -x "$X_RAY_BIN" ]; then
    echo "未安装 Xray 或 $X_RAY_BIN 不可执行。" | tee -a "$LOG_FILE"
    exit 1
fi
current_version=$("$X_RAY_BIN" -version 2>/dev/null | grep 'Xray' | head -n1 | awk '{print $2}')
#测试脚本能否正常使用
#current_version="25.5.15"
echo "当前版本：$current_version" | tee -a "$LOG_FILE"

# 3. 获取最新版本信息
release_info=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest)
download_url=$(echo "$release_info" | jq -r ".assets[] | select(.name==\"$xray_file\") | .browser_download_url")
latest_version=$(echo "$release_info" | jq -r ".tag_name")

if [[ -z "$download_url" || "$download_url" == "null" ]]; then
    echo "无法获取对应架构 [$arch] 的下载地址。" | tee -a "$LOG_FILE"
    exit 1
fi

echo "最新版本：$latest_version" | tee -a "$LOG_FILE"

clean_current_version=$(echo "$current_version" | sed 's/^v//')
clean_latest_version=$(echo "$latest_version" | sed 's/^v//')

# 4. 版本对比
if [[ "$clean_current_version" == "$clean_latest_version" ]]; then
    echo "✅ 当前 Xray 已是最新版本，无需更新。" | tee -a "$LOG_FILE"
    exit 0
fi

echo "⬇️ 开始下载新版本..." | tee -a "$LOG_FILE"
tmp_dir=$(mktemp -d)
wget -O "$tmp_dir/$xray_file" "$download_url"

echo "📦 解压文件..." | tee -a "$LOG_FILE"
unzip -o "$tmp_dir/$xray_file" -d "$tmp_dir/xray-update"

# 5. 停止 Xray 服务，支持 systemd 或 OpenWrt init.d
echo "停止 Xray 服务..." | tee -a "$LOG_FILE"
if command -v systemctl >/dev/null 2>&1; then
    systemctl stop xray
else
    /etc/init.d/xray stop || true
fi

# 6. 备份旧版本，只保留最近一次备份
echo "备份旧版本..." | tee -a "$LOG_FILE"
backup_file="${BACKUP_DIR}/xray.bak"
if [ -f "$backup_file" ]; then
    rm -f "$backup_file"
fi
cp "$X_RAY_BIN" "$backup_file"

# 7. 替换 Xray 并赋权
echo "替换 Xray 核心..." | tee -a "$LOG_FILE"
mv "$tmp_dir/xray-update/xray" "$X_RAY_BIN"
chmod +x "$X_RAY_BIN"

# 8. 启动 Xray 服务
echo "启动 Xray 服务..." | tee -a "$LOG_FILE"
if command -v systemctl >/dev/null 2>&1; then
    systemctl start xray
else
    /etc/init.d/xray start || true
fi

# 9. 清理临时文件
echo "清理临时文件..." | tee -a "$LOG_FILE"
rm -rf "$tmp_dir"

echo "✅ Xray 已成功从版本 $current_version 更新至 $latest_version 并完成重启。" | tee -a "$LOG_FILE"
