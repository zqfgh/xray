#!/bin/bash
set -e

# 设置日志文件和备份目录
LOG_FILE="/var/log/xray_update.log"
# 确保日志文件路径存在
mkdir -p "$(dirname "$LOG_FILE")"
# 初始化或清空日志文件
echo "" > "$LOG_FILE"

# 判断是否已安装 xray，并获取路径
X_RAY_BIN=$(command -v xray)
if [ -z "$X_RAY_BIN" ]; then
    echo "$(date) 未检测到 xray 可执行文件，请先安装 Xray。" | tee -a "$LOG_FILE"
    exit 1
fi

BACKUP_DIR=$(dirname "$X_RAY_BIN")

echo "$(date) 开始执行 Xray 更新任务" | tee -a "$LOG_FILE"

# 测试是否可以直接访问 GitHub，不使用代理
echo "$(date) 检测 GitHub 直连状态..." | tee -a "$LOG_FILE"
if curl --connect-timeout 10 -s https://github.com > /dev/null 2>&1; then # 增加超时时间
    echo "$(date) 检测到可直连 GitHub，取消代理设置。" | tee -a "$LOG_FILE"
    unset http_proxy
    unset https_proxy
else
    echo "$(date) 无法直连 GitHub，启用 HTTP 代理 127.0.0.1:7890" | tee -a "$LOG_FILE"
    export http_proxy="http://127.0.0.1:7890"
    export https_proxy="http://127.0.0.1:7890"

    # 代理启用后，再次测试代理是否生效
    echo "$(date) 检查代理连接 GitHub API..." | tee -a "$LOG_FILE"
    if ! curl --connect-timeout 10 -s https://api.github.com/repos/XTLS/Xray-core/releases/latest > /dev/null 2>&1; then
        echo "$(date) ⚠️ 警告: 代理启用后仍无法访问 GitHub API。请检查 127.0.0.1:7890 的 Xray/代理服务是否正常运行或配置正确。" | tee -a "$LOG_FILE"
        # 如果代理不工作，这里选择退出，因为后续操作依赖 GitHub API
        exit 1
    else
        echo "$(date) 代理连接 GitHub API 成功。" | tee -a "$LOG_FILE"
    fi
fi

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 检查 jq 是否已安装
if ! command -v jq >/dev/null 2>&1; then
    echo "$(date) 未检测到 jq，正在尝试安装..." | tee -a "$LOG_FILE"
    if command -v apt >/dev/null 2>&1; then
        apt update && apt install -y jq
    elif command -v apk >/dev/null 2>&1; then
        apk add jq
    elif command -v yum >/dev/null 2>&1; then
        yum install -y jq
    else
        echo "$(date) 无法自动安装 jq，请手动安装后重试。" | tee -a "$LOG_FILE"
        exit 1
    fi
    # 再次检查 jq 是否安装成功
    if ! command -v jq >/dev/null 2>&1; then
        echo "$(date) jq 安装失败，请手动安装后重试。" | tee -a "$LOG_FILE"
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
        echo "$(date) 不支持的架构: $arch" | tee -a "$LOG_FILE"
        exit 1
        ;;
esac
echo "$(date) 检测到架构: $arch, 对应下载文件: $xray_file" | tee -a "$LOG_FILE"

# 2. 获取当前版本
if [ ! -x "$X_RAY_BIN" ]; then
    echo "$(date) 检测到的 Xray 文件不可执行：$X_RAY_BIN" | tee -a "$LOG_FILE"
    exit 1
fi
current_version=$("$X_RAY_BIN" -version 2>/dev/null | grep 'Xray' | head -n1 | awk '{print $2}')
if [ -z "$current_version" ]; then
    echo "$(date) 无法获取当前 Xray 版本，请检查 Xray 是否安装正确或可执行。" | tee -a "$LOG_FILE"
    exit 1
fi
echo "$(date) 当前版本：$current_version" | tee -a "$LOG_FILE"

# 3. 获取最新版本信息
echo "$(date) 正在从 GitHub API 获取最新版本信息..." | tee -a "$LOG_FILE"
# 使用 -L 选项跟随重定向，增加超时，并获取HTTP状态码
HTTP_STATUS=$(curl -s -L -o /dev/null -w "%{http_code}" --connect-timeout 15 --max-time 30 https://api.github.com/repos/XTLS/Xray-core/releases/latest)
release_info=$(curl -s -L --connect-timeout 15 --max-time 30 https://api.github.com/repos/XTLS/Xray-core/releases/latest)

echo "$(date) GitHub API 响应 HTTP 状态码: $HTTP_STATUS" | tee -a "$LOG_FILE"

if [[ "$HTTP_STATUS" -ne 200 ]]; then
    echo "$(date) 错误: 无法从 GitHub API 获取到最新版本信息。HTTP 状态码: $HTTP_STATUS" | tee -a "$LOG_FILE"
    echo "$(date) 完整的 GitHub API 响应内容:" | tee -a "$LOG_FILE"
    echo "$release_info" | tee -a "$LOG_FILE" # 打印完整的响应内容以供调试
    exit 1
fi

# 检查 release_info 是否为空或无效 JSON
if [[ -z "$release_info" || "$(echo "$release_info" | jq 'type' 2>/dev/null)" != "\"object\"" ]]; then
    echo "$(date) 错误: GitHub API 返回内容为空或不是有效的 JSON。请检查网络或代理设置。" | tee -a "$LOG_FILE"
    echo "$(date) 返回内容示例 (前500字符): ${release_info:0:500}" | tee -a "$LOG_FILE"
    exit 1
fi

download_url=$(echo "$release_info" | jq -r ".assets[] | select(.name==\"$xray_file\") | .browser_download_url")
latest_version=$(echo "$release_info" | jq -r ".tag_name")

if [[ -z "$download_url" || "$download_url" == "null" ]]; then
    echo "$(date) 错误: 无法获取对应架构 [$arch] 的下载地址。" | tee -a "$LOG_FILE"
    echo "$(date) GitHub API 完整响应内容如下，请检查其中是否存在 [$xray_file] 对应下载链接：" | tee -a "$LOG_FILE"
    echo "$release_info" | tee -a "$LOG_FILE"
    exit 1
fi

echo "$(date) 最新版本：$latest_version" | tee -a "$LOG_FILE"

clean_current_version=$(echo "$current_version" | sed 's/^v//')
clean_latest_version=$(echo "$latest_version" | sed 's/^v//')

# 4. 版本对比
if [[ "$clean_current_version" == "$clean_latest_version" ]]; then
    echo "$(date) ✅ 当前 Xray 已是最新版本，无需更新。" | tee -a "$LOG_FILE"
    exit 0
fi

echo "$(date) ⬇️ 开始下载新版本..." | tee -a "$LOG_FILE"
tmp_dir=$(mktemp -d /tmp/xray-update.XXXXXX) # 使用更安全的临时目录创建方式
if [ ! -d "$tmp_dir" ]; then
    echo "$(date) 错误: 无法创建临时目录 $tmp_dir。" | tee -a "$LOG_FILE"
    exit 1
fi
echo "$(date) 临时下载目录: $tmp_dir" | tee -a "$LOG_FILE"

# 下载文件，增加超时和重试
if ! wget -O "$tmp_dir/$xray_file" "$download_url" --timeout=30 --tries=3; then
    echo "$(date) 错误: 下载新版本失败。" | tee -a "$LOG_FILE"
    rm -rf "$tmp_dir"
    exit 1
fi

echo "$(date) 📦 解压文件..." | tee -a "$LOG_FILE"
# 检查 zip 文件是否有效
if ! unzip -t "$tmp_dir/$xray_file" >/dev/null 2>&1; then
    echo "$(date) 错误: 下载的 zip 文件损坏或无效。" | tee -a "$LOG_FILE"
    rm -rf "$tmp_dir"
    exit 1
fi

unzip -o "$tmp_dir/$xray_file" -d "$tmp_dir/xray-update"

# 检查解压后的 xray 可执行文件是否存在
if [ ! -f "$tmp_dir/xray-update/xray" ]; then
    echo "$(date) 错误: 解压后未找到 xray 可执行文件。" | tee -a "$LOG_FILE"
    rm -rf "$tmp_dir"
    exit 1
fi

# 5. 停止 Xray 服务，支持 systemd 或 OpenWrt init.d
echo "$(date) 停止 Xray 服务..." | tee -a "$LOG_FILE"
if command -v systemctl >/dev/null 2>&1; then
    systemctl stop xray || true # 允许服务未运行的情况
else
    /etc/init.d/xray stop || true
fi

# 6. 备份旧版本，只保留最近一次备份
echo "$(date) 备份旧版本..." | tee -a "$LOG_FILE"
backup_file="${BACKUP_DIR}/xray.bak"
if [ -f "$backup_file" ]; then
    echo "$(date) 移除旧备份文件: $backup_file" | tee -a "$LOG_FILE"
    rm -f "$backup_file"
fi
cp "$X_RAY_BIN" "$backup_file"
echo "$(date) 旧版本已备份到 $backup_file" | tee -a "$LOG_FILE"

# 7. 替换 Xray 并赋权
echo "$(date) 替换 Xray 核心..." | tee -a "$LOG_FILE"
mv "$tmp_dir/xray-update/xray" "$X_RAY_BIN"
chmod +x "$X_RAY_BIN"
echo "$(date) Xray 核心已更新并赋权。" | tee -a "$LOG_FILE"

# 8. 启动 Xray 服务
echo "$(date) 启动 Xray 服务..." | tee -a "$LOG_FILE"
if command -v systemctl >/dev/null 2>&1; then
    systemctl start xray
else
    /etc/init.d/xray start || true
fi
echo "$(date) Xray 服务启动命令已执行。" | tee -a "$LOG_FILE"

# 9. 清理临时文件
echo "$(date) 清理临时文件..." | tee -a "$LOG_FILE"
rm -rf "$tmp_dir"

echo "$(date) ✅ Xray 已成功从版本 $current_version 更新至 $latest_version 并完成重启。" | tee -a "$LOG_FILE"
