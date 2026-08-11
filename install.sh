#!/bin/sh
set -eu

REPOSITORY="mikutea/istoreOS-sms"
REF="${ISTOREOS_SMS_REF:-main}"
RAW_BASE="https://raw.githubusercontent.com/${REPOSITORY}/${REF}"
STAGE="/tmp/istoreos-sms-install.$$"
TOTAL_STEPS=7

PAYLOADS="
htdocs/luci-static/resources/view/services/istoreos-sms.js
root/etc/config/istoreos_sms
root/etc/init.d/istoreos_sms
root/usr/libexec/istoreos-sms/ensure-storage.sh
root/usr/share/luci/menu.d/istoreos-sms.json
root/usr/share/rpcd/acl.d/istoreos-sms.json
"

log_step() {
  printf '[%s/%s] %s\n' "$1" "$TOTAL_STEPS" "$2"
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "请使用 root 权限运行安装脚本"
}

cleanup() {
  rm -rf "$STAGE"
}

fetch_file() {
  src="$1"
  dst="$2"

  mkdir -p "$(dirname "$dst")"
  if command -v uclient-fetch >/dev/null 2>&1; then
    uclient-fetch -q -O "$dst" "$src"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$dst" "$src"
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL "$src" -o "$dst"
  else
    die "未找到 uclient-fetch、wget 或 curl"
  fi
}

stage_payloads() {
  script_dir=""
  if [ -n "${0:-}" ] && [ -f "$0" ]; then
    script_dir="$(CDPATH= cd "$(dirname "$0")" && pwd)"
  fi

  for rel in $PAYLOADS; do
    dst="$STAGE/$rel"
    mkdir -p "$(dirname "$dst")"
    if [ -n "$script_dir" ] && [ -f "$script_dir/$rel" ]; then
      cp "$script_dir/$rel" "$dst"
    else
      fetch_file "$RAW_BASE/$rel" "$dst"
    fi
    [ -s "$dst" ] || die "下载的文件为空：$rel"
  done
}

install_file() {
  rel="$1"
  target="$2"
  mode="$3"
  mkdir -p "$(dirname "$target")"
  cp "$STAGE/$rel" "$target"
  chmod "$mode" "$target"
}

detect_device() {
  configured="$(uci -q get sms_tool_js.@sms_tool_js[0].readport 2>/dev/null || true)"
  case "$configured" in
    /dev/ttyUSB*|/dev/ttyACM*|/dev/ttyS*|/dev/mhi_*|/dev/wwan*)
      printf '%s\n' "$configured"
      return
      ;;
  esac

  for candidate in /dev/ttyUSB3 /dev/ttyUSB2 /dev/ttyUSB1 /dev/ttyACM0; do
    if [ -e "$candidate" ]; then
      printf '%s\n' "$candidate"
      return
    fi
  done

  printf '%s\n' '/dev/ttyUSB2'
}

configure_uci() {
  new_config=0
  if [ ! -f /etc/config/istoreos_sms ]; then
    cp "$STAGE/root/etc/config/istoreos_sms" /etc/config/istoreos_sms
    chmod 600 /etc/config/istoreos_sms
    new_config=1
  fi

  uci -q get istoreos_sms.main >/dev/null 2>&1 || uci set istoreos_sms.main='istoreos_sms'

  current_device="$(uci -q get istoreos_sms.main.device 2>/dev/null || true)"
  if [ "$new_config" -eq 1 ] || [ -z "$current_device" ]; then
    uci set istoreos_sms.main.device="$(detect_device)"
  fi

  current_storage="$(uci -q get istoreos_sms.main.storage 2>/dev/null || true)"
  case "$current_storage" in
    SM|ME|MT) ;;
    *)
      upstream_storage="$(uci -q get sms_tool_js.@sms_tool_js[0].storage 2>/dev/null || true)"
      case "$upstream_storage" in
        SM|ME|MT) uci set istoreos_sms.main.storage="$upstream_storage" ;;
        *) uci set istoreos_sms.main.storage='SM' ;;
      esac
      ;;
  esac

  uci -q get istoreos_sms.main.auto_repair >/dev/null 2>&1 || \
    uci set istoreos_sms.main.auto_repair='1'
  uci set istoreos_sms.main.initialized='1'
  uci commit istoreos_sms
}

remove_known_legacy_files() {
  legacy_controller='/usr/lib/lua/luci/controller/sms.lua'
  legacy_view='/usr/lib/lua/luci/view/sms/page.htm'

  if [ -f "$legacy_controller" ] && grep -q 'luci.controller.sms' "$legacy_controller"; then
    rm -f "$legacy_controller"
  fi
  if [ -f "$legacy_view" ] && grep -q 'sms-wrap' "$legacy_view"; then
    rm -f "$legacy_view"
    rmdir /usr/lib/lua/luci/view/sms 2>/dev/null || true
  fi
}

require_root
umask 022
trap cleanup EXIT INT TERM
mkdir -p "$STAGE"

log_step 1 "检查 sms_tool 依赖..."
command -v sms_tool >/dev/null 2>&1 || die "未检测到 sms_tool，请先安装后重试"

log_step 2 "准备并校验安装文件（ref: $REF）..."
stage_payloads

log_step 3 "安装现代 LuCI 页面、菜单和 ACL..."
install_file 'htdocs/luci-static/resources/view/services/istoreos-sms.js' \
  '/www/luci-static/resources/view/services/istoreos-sms.js' 0644
install_file 'root/usr/share/luci/menu.d/istoreos-sms.json' \
  '/usr/share/luci/menu.d/istoreos-sms.json' 0644
install_file 'root/usr/share/rpcd/acl.d/istoreos-sms.json' \
  '/usr/share/rpcd/acl.d/istoreos-sms.json' 0644

log_step 4 "安装开机接收模式自检..."
install_file 'root/usr/libexec/istoreos-sms/ensure-storage.sh' \
  '/usr/libexec/istoreos-sms/ensure-storage.sh' 0755
install_file 'root/etc/init.d/istoreos_sms' '/etc/init.d/istoreos_sms' 0755

log_step 5 "创建或保留 UCI 配置..."
configure_uci
remove_known_legacy_files

log_step 6 "刷新 LuCI/rpcd 并运行一次健康检查..."
rm -f /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
command -v luci-reload >/dev/null 2>&1 && luci-reload >/dev/null 2>&1 || true

if [ "$(uci -q get istoreos_sms.main.auto_repair 2>/dev/null || true)" = '1' ]; then
  /etc/init.d/istoreos_sms enable >/dev/null 2>&1 || true
  /etc/init.d/istoreos_sms restart >/dev/null 2>&1 || true
else
  /etc/init.d/istoreos_sms disable >/dev/null 2>&1 || true
fi

log_step 7 "完成。LuCI -> 服务 -> 短信（iStoreOS-SMS）"
printf '设备：%s\n' "$(uci -q get istoreos_sms.main.device)"
printf '存储：%s\n' "$(uci -q get istoreos_sms.main.storage)"
