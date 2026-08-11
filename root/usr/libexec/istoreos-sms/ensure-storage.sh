#!/bin/sh
set -eu

TAG='istoreos-sms'
DEVICE="$(uci -q get istoreos_sms.main.device 2>/dev/null || true)"

case "$DEVICE" in
	/dev/ttyUSB*|/dev/ttyACM*|/dev/ttyS*|/dev/mhi_*|/dev/wwan*) ;;
	*)
		logger -t "$TAG" "拒绝无效串口路径：$DEVICE"
		exit 1
		;;
esac

attempt=0
while [ "$attempt" -lt 12 ]; do
	[ -e "$DEVICE" ] && break
	attempt=$((attempt + 1))
	sleep 5
done

if [ ! -e "$DEVICE" ]; then
	logger -t "$TAG" "等待 60 秒后仍未发现串口：$DEVICE"
	exit 1
fi

current="$(sms_tool -d "$DEVICE" at 'AT+CNMI?' 2>&1 || true)"
compact="$(printf '%s' "$current" | tr -d ' \r\n')"
case "$compact" in
	*'+CNMI:2,1,0,0,0'*)
		logger -t "$TAG" "CNMI 已是存储型接收模式：$DEVICE"
		exit 0
		;;
esac

result="$(sms_tool -d "$DEVICE" at 'AT+CNMI=2,1,0,0,0' 2>&1 || true)"
case "$result" in
	*OK*)
		logger -t "$TAG" "已将 CNMI 修复为 2,1,0,0,0：$DEVICE"
		exit 0
		;;
	*)
		logger -t "$TAG" "CNMI 修复失败：$DEVICE"
		exit 1
		;;
esac
