#!/bin/sh
set -eu

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

[ "$(id -u)" -eq 0 ] || die "请使用 root 权限运行卸载脚本"

/etc/init.d/istoreos_sms stop >/dev/null 2>&1 || true
/etc/init.d/istoreos_sms disable >/dev/null 2>&1 || true

rm -f /etc/init.d/istoreos_sms
rm -f /usr/libexec/istoreos-sms/ensure-storage.sh
rm -f /usr/share/luci/menu.d/istoreos-sms.json
rm -f /usr/share/rpcd/acl.d/istoreos-sms.json
rm -f /www/luci-static/resources/view/services/istoreos-sms.js

rmdir /usr/libexec/istoreos-sms 2>/dev/null || true

legacy_controller='/usr/lib/lua/luci/controller/sms.lua'
legacy_view='/usr/lib/lua/luci/view/sms/page.htm'
if [ -f "$legacy_controller" ] && grep -q 'luci.controller.sms' "$legacy_controller"; then
  rm -f "$legacy_controller"
fi
if [ -f "$legacy_view" ] && grep -q 'sms-wrap' "$legacy_view"; then
  rm -f "$legacy_view"
  rmdir /usr/lib/lua/luci/view/sms 2>/dev/null || true
fi

if [ "${PURGE_CONFIG:-0}" = '1' ]; then
  rm -f /etc/config/istoreos_sms
  printf '配置已删除。\n'
else
  printf '配置已保留：/etc/config/istoreos_sms\n'
fi

rm -f /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
command -v luci-reload >/dev/null 2>&1 && luci-reload >/dev/null 2>&1 || true

printf 'iStoreOS-SMS 已卸载。现有 luci-app-sms-tool-js 未被修改。\n'
