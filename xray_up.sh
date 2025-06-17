#!/bin/bash
set -e

# Set log file and backup directory
LOG_FILE="/var/log/xray_update.log"
# Ensure the log file path exists
mkdir -p "$(dirname "$LOG_FILE")"
# Initialize or clear the log file
echo "" > "$LOG_FILE"

# Check if xray is installed and get its path
X_RAY_BIN=$(command -v xray)
if [ -z "$X_RAY_BIN" ]; then
    echo "$(date) Xray executable not found, please install Xray first." | tee -a "$LOG_FILE"
    exit 1
fi

BACKUP_DIR=$(dirname "$X_RAY_BIN")

echo "$(date) Starting Xray update task" | tee -a "$LOG_FILE"

# Test if GitHub can be accessed directly, without a proxy
echo "$(date) Checking direct GitHub connection status..." | tee -a "$LOG_FILE"
if curl --connect-timeout 10 -s https://github.com > /dev/null 2>&1; then # Increase timeout
    echo "$(date) Direct GitHub connection detected, cancelling proxy settings." | tee -a "$LOG_FILE"
    #unset http_proxy
    #unset https_proxy
else
    echo "$(date) Cannot connect to GitHub directly, enabling HTTP proxy 127.0.0.1:7890" | tee -a "$LOG_FILE"
    export http_proxy="http://127.0.0.1:7890"
    export https_proxy="http://127.0.0.1:7890"

    # After enabling proxy, re-test if proxy is working
    echo "$(date) Checking proxy connection to GitHub API..." | tee -a "$LOG_FILE"
    if ! curl --connect-timeout 10 -s https://api.github.com/repos/XTLS/Xray-core/releases/latest > /dev/null 2>&1; then
        echo "$(date) ⚠️ Warning: Unable to access GitHub API even with proxy enabled. Please check if Xray/proxy service on 127.0.0.1:7890 is running or configured correctly." | tee -a "$LOG_FILE"
        # If proxy is not working, exit here, as subsequent operations depend on GitHub API
        exit 1
    else
        echo "$(date) Proxy connection to GitHub API successful." | tee -a "$LOG_FILE"
    fi
fi

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Check if jq is installed
if ! command -v jq >/dev/null 2>&1; then
    echo "$(date) jq not detected, attempting to install..." | tee -a "$LOG_FILE"
    if command -v apt >/dev/null 2>&1; then
        apt update && apt install -y jq
    elif command -v apk >/dev/null 2>&1; then
        apk add jq
    elif command -v yum >/dev/null 2>&1; then
        yum install -y jq
    else
        echo "$(date) Unable to automatically install jq, please install manually and retry." | tee -a "$LOG_FILE"
        exit 1
    fi
    # Re-check if jq installed successfully
    if ! command -v jq >/dev/null 2>&1; then
        echo "$(date) jq installation failed, please install manually and retry." | tee -a "$LOG_FILE"
        exit 1
    fi
fi

# 1. Detect architecture
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
        echo "$(date) Unsupported architecture: $arch" | tee -a "$LOG_FILE"
        exit 1
        ;;
esac
echo "$(date) Detected architecture: $arch, corresponding download file: $xray_file" | tee -a "$LOG_FILE"

# 2. Get current version
if [ ! -x "$X_RAY_BIN" ]; then
    echo "$(date) Detected Xray file is not executable: $X_RAY_BIN" | tee -a "$LOG_FILE"
    exit 1
fi
current_version=$("$X_RAY_BIN" -version 2>/dev/null | grep 'Xray' | head -n1 | awk '{print $2}')
if [ -z "$current_version" ]; then
    echo "$(date) Unable to get current Xray version, please check if Xray is installed correctly or is executable." | tee -a "$LOG_FILE"
    exit 1
fi
echo "$(date) Current version: $current_version" | tee -a "$LOG_FILE"

# 3. Get latest version information
echo "$(date) Getting latest version information from GitHub API..." | tee -a "$LOG_FILE"
# Use -L to follow redirects, increase timeout, and get HTTP status code
HTTP_STATUS=$(curl -s -L -o /dev/null -w "%{http_code}" --connect-timeout 15 --max-time 30 https://api.github.com/repos/XTLS/Xray-core/releases/latest)
release_info=$(curl -s -L --connect-timeout 15 --max-time 30 https://api.github.com/repos/XTLS/Xray-core/releases/latest)

echo "$(date) GitHub API response HTTP status code: $HTTP_STATUS" | tee -a "$LOG_FILE"

if [[ "$HTTP_STATUS" -ne 200 ]]; then
    echo "$(date) Error: Unable to get latest version information from GitHub API. HTTP status code: $HTTP_STATUS" | tee -a "$LOG_FILE"
    echo "$(date) Full GitHub API response content:" | tee -a "$LOG_FILE"
    echo "$release_info" | tee -a "$LOG_FILE" # Print full response content for debugging
    exit 1
fi

# Check if release_info is empty or invalid JSON
if [[ -z "$release_info" || "$(echo "$release_info" | jq 'type' 2>/dev/null)" != "\"object\"" ]]; then
    echo "$(date) Error: GitHub API returned empty or invalid JSON content. Please check network or proxy settings." | tee -a "$LOG_FILE"
    echo "$(date) Response content (first 500 characters): ${release_info:0:500}" | tee -a "$LOG_FILE"
    exit 1
fi

download_url=$(echo "$release_info" | jq -r ".assets[] | select(.name==\"$xray_file\") | .browser_download_url")
latest_version=$(echo "$release_info" | jq -r ".tag_name")

if [[ -z "$download_url" || "$download_url" == "null" ]]; then
    echo "$(date) Error: Unable to get download URL for architecture [$arch]." | tee -a "$LOG_FILE"
    echo "$(date) Full GitHub API response content below, please check if there is a download link for [$xray_file]:" | tee -a "$LOG_FILE"
    echo "$release_info" | tee -a "$LOG_FILE"
    exit 1
fi

echo "$(date) Latest version: $latest_version" | tee -a "$LOG_FILE"

clean_current_version=$(echo "$current_version" | sed 's/^v//')
clean_latest_version=$(echo "$latest_version" | sed 's/^v//')

# 4. Version comparison
if [[ "$clean_current_version" == "$clean_latest_version" ]]; then
    echo "$(date) ✅ Current Xray is already the latest version, no update needed." | tee -a "$LOG_FILE"
    exit 0
fi

echo "$(date) ⬇️ Starting new version download..." | tee -a "$LOG_FILE"
tmp_dir=$(mktemp -d /tmp/xray-update.XXXXXX) # Use a more secure way to create temporary directory
if [ ! -d "$tmp_dir" ]; then
    echo "$(date) Error: Could not create temporary directory $tmp_dir." | tee -a "$LOG_FILE"
    exit 1
fi
echo "$(date) Temporary download directory: $tmp_dir" | tee -a "$LOG_FILE"

# Download file, add timeout and retries
if ! wget -O "$tmp_dir/$xray_file" "$download_url" --timeout=30 --tries=3; then
    echo "$(date) Error: Failed to download new version." | tee -a "$LOG_FILE"
    rm -rf "$tmp_dir"
    exit 1
fi

echo "$(date) 📦 Extracting files..." | tee -a "$LOG_FILE"
# Check if the zip file is valid
if ! unzip -t "$tmp_dir/$xray_file" >/dev/null 2>&1; then
    echo "$(date) Error: Downloaded zip file is corrupted or invalid." | tee -a "$LOG_FILE"
    rm -rf "$tmp_dir"
    exit 1
fi

unzip -o "$tmp_dir/$xray_file" -d "$tmp_dir/xray-update"

# Check if the extracted xray executable exists
if [ ! -f "$tmp_dir/xray-update/xray" ]; then
    echo "$(date) Error: Xray executable not found after extraction." | tee -a "$LOG_FILE"
    rm -rf "$tmp_dir"
    exit 1
fi

# 5. Stop Xray service, supports systemd or OpenWrt init.d
echo "$(date) Stopping Xray service..." | tee -a "$LOG_FILE"
if command -v systemctl >/dev/null 2>&1; then
    systemctl stop xray || true # Allow for cases where the service might not be running
else
    /etc/init.d/xray stop || true
fi

# 6. Backup old version, keep only the latest backup
echo "$(date) Backing up old version..." | tee -a "$LOG_FILE"
backup_file="${BACKUP_DIR}/xray.bak"
if [ -f "$backup_file" ]; then
    echo "$(date) Removing old backup file: $backup_file" | tee -a "$LOG_FILE"
    rm -f "$backup_file"
fi
cp "$X_RAY_BIN" "$backup_file"
echo "$(date) Old version backed up to $backup_file" | tee -a "$LOG_FILE"

# 7. Replace Xray and set permissions
echo "$(date) Replacing Xray core..." | tee -a "$LOG_FILE"
mv "$tmp_dir/xray-update/xray" "$X_RAY_BIN"
chmod +x "$X_RAY_BIN"
echo "$(date) Xray core updated and permissions set." | tee -a "$LOG_FILE"

# 8. Start Xray service
echo "$(date) Starting Xray service..." | tee -a "$LOG_FILE"
if command -v systemctl >/dev/null 2>&1; then
    systemctl start xray
else
    /etc/init.d/xray start || true
fi
echo "$(date) Xray service start command executed." | tee -a "$LOG_FILE"

# 9. Clean up temporary files
echo "$(date) Cleaning up temporary files..." | tee -a "$LOG_FILE"
rm -rf "$tmp_dir"

echo "$(date) ✅ Xray successfully updated from version $current_version to $latest_version and restarted." | tee -a "$LOG_FILE"
