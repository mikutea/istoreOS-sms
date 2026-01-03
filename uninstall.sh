#!/bin/sh
set -eu

CTRL="/usr/lib/lua/luci/controller/sms.lua"
VIEW_DIR="/usr/lib/lua/luci/view/sms"
BACKEND="/usr/libexec/sms/sms.uc"
CFG="/etc/config/smsfix"

rm -f "$CTRL" 2>/dev/null || true
rm -f "$BACKEND" 2>/dev/null || true
rm -rf "$VIEW_DIR" 2>/dev/null || true
# 配置文件是否删除看你需求：这里也删掉
rm -f "$CFG" 2>/dev/null || true

rm -f /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
command -v luci-reload >/dev/null 2>&1 && luci-reload >/dev/null 2>&1 || true

echo "Uninstalled. (Ctrl+F5 refresh LuCI if needed)"
