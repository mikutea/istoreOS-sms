# iStoreOS-SMS

面向 iStoreOS / OpenWrt 的轻量短信查看器。项目使用现代 LuCI JavaScript
页面调用 `sms_tool`，可以和
[`4IceG/luci-app-sms-tool-js`](https://github.com/4IceG/luci-app-sms-tool-js)
并存，不覆盖它的菜单、配置或文件。

## 这次修复了什么

### 收到短信但 LuCI 看不到

如果调制解调器返回类似下面的配置：

```text
AT+CNMI?
+CNMI: 3,2,1,1,1
```

其中第二个参数 `<mt>=2` 会把新短信直接作为 `+CMT` 推送到当前串口，而不是先
存入 SIM/模块存储。没有常驻程序监听串口时，这条短信就不会出现在只读取存储区的
LuCI 页面中。

本项目采用的存储型配置是：

```text
AT+CNMI=2,1,0,0,0
```

此时 `<mt>=1`，新短信写入存储区并通过 `+CMTI` 指示。页面再通过
`sms_tool -s SM ... recv` 读取即可。Quectel RM500U 系列 AT 手册也将
`2,1,0,0,0` 列为默认组合，并说明了 `<mt>=1` 与 `<mt>=2` 的差异：

- [Quectel RGx00U / RM500U AT Commands Manual V1.0](https://quectel.com/content/uploads/2024/02/Quectel_RGx00URM500U_Series_AT_Commands_Manual_V1.0.pdf)

新版页面会显示当前 `CNMI` 状态，提供“一键修复接收模式”按钮；默认启用的开机
自检只在配置不正确时写入上述参数。

### OpenWrt 24.10 兼容性

旧版仓库写入 `/usr/lib/lua/luci/controller` 和 `/usr/lib/lua/luci/view`，依赖旧式
LuCI Lua 控制器。新版已迁移为：

- `/usr/share/luci/menu.d` 菜单定义；
- `/www/luci-static/resources/view` LuCI JS 页面；
- 精确到文件和 UCI 配置的 rpcd ACL；
- 独立的 `/etc/config/istoreos_sms` 配置；
- 可选的 procd 开机接收模式自检。

## 功能

- 读取 SIM、模块或组合存储中的短信；
- 使用 `sms_tool` 解码 GSM 7-bit、UCS2 和长短信分片；
- 按时间倒序显示并合并完整的长短信；
- 按号码、时间或正文即时搜索；
- 持久化串口和存储区配置；
- 检查并修复会导致“收到了但页面看不到”的 `CNMI` 配置；
- 不拼接用户输入为 shell 命令，且只授权执行必要文件。

## 依赖

路由器必须已经安装：

```text
sms_tool
```

安装脚本会先检查依赖；缺失时会停止，不会留下半安装状态。

## 安装

```sh
sh -c "$(wget -qO- https://raw.githubusercontent.com/mikutea/istoreOS-sms/main/install.sh)"
```

或：

```sh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/mikutea/istoreOS-sms/main/install.sh)"
```

从克隆目录安装也可以：

```sh
sh install.sh
```

安装完成后进入：

```text
LuCI -> 服务 -> 短信（iStoreOS-SMS）
```

安装器会优先沿用 `luci-app-sms-tool-js` 已配置的读取串口；否则按设备存在情况选择
`/dev/ttyUSB3` 或 `/dev/ttyUSB2`。页面中可以随时修改并保存。

## 手工排障

将串口替换为实际 AT 端口：

```sh
sms_tool -d /dev/ttyUSB3 at 'AT+CPMS?'
sms_tool -d /dev/ttyUSB3 at 'AT+CNMI?'
sms_tool -s SM -d /dev/ttyUSB3 status
sms_tool -s SM -d /dev/ttyUSB3 -f '%Y-%m-%d %H:%M:%S' -j recv
```

如果 `AT+CNMI?` 的第二个参数是 `2`，且没有常驻进程接收 `+CMT`，执行：

```sh
sms_tool -d /dev/ttyUSB3 at 'AT+CNMI=2,1,0,0,0'
sms_tool -d /dev/ttyUSB3 at 'AT+CNMI?'
```

注意：AT 串口通常只能被一个进程占用。执行检查时请避免同时运行 ModemManager、
另一个短信守护进程或其他串口终端。

## 配置

```sh
uci set istoreos_sms.main.device='/dev/ttyUSB3'
uci set istoreos_sms.main.storage='SM'
uci set istoreos_sms.main.auto_repair='1'
uci commit istoreos_sms
/etc/init.d/istoreos_sms enable
/etc/init.d/istoreos_sms restart
```

将 `auto_repair` 设为 `0` 可关闭开机检查。

## 卸载与回滚

```sh
sh -c "$(wget -qO- https://raw.githubusercontent.com/mikutea/istoreOS-sms/main/uninstall.sh)"
```

默认保留 `/etc/config/istoreos_sms`，方便重新安装。确认要连配置一起删除时：

```sh
PURGE_CONFIG=1 sh uninstall.sh
```

卸载不会修改或删除 `luci-app-sms-tool-js`，也不会尝试恢复无法可靠推断的旧
`CNMI` 参数。

## 验证

仓库包含静态验证，检查 shell 语法、JSON、LuCI 视图语法、菜单映射和安装/卸载
清单：

```sh
bash -n install.sh uninstall.sh root/etc/init.d/istoreos_sms \
  root/usr/libexec/istoreos-sms/ensure-storage.sh
python tests/validate_repo.py
node tests/parse-luci-view.mjs
```

## License

MIT © mikutea
