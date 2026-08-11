import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


expected_payloads = {
    "htdocs/luci-static/resources/view/services/istoreos-sms.js",
    "root/etc/config/istoreos_sms",
    "root/etc/init.d/istoreos_sms",
    "root/usr/libexec/istoreos-sms/ensure-storage.sh",
    "root/usr/share/luci/menu.d/istoreos-sms.json",
    "root/usr/share/rpcd/acl.d/istoreos-sms.json",
}

for relative in expected_payloads:
    path = ROOT / relative
    assert path.is_file(), f"missing payload: {relative}"
    assert path.stat().st_size > 0, f"empty payload: {relative}"

menu = json.loads(read("root/usr/share/luci/menu.d/istoreos-sms.json"))
entry = menu["admin/services/istoreos-sms"]
assert entry["action"] == {"type": "view", "path": "services/istoreos-sms"}
assert entry["depends"]["acl"] == ["luci-app-istoreos-sms"]

acl = json.loads(read("root/usr/share/rpcd/acl.d/istoreos-sms.json"))
grant = acl["luci-app-istoreos-sms"]
assert grant["read"]["uci"] == ["istoreos_sms"]
assert "/usr/bin/sms_tool" in grant["read"]["file"]

installer = read("install.sh")
uninstaller = read("uninstall.sh")
for relative in expected_payloads:
    assert relative in installer, f"installer does not stage: {relative}"

installed_targets = {
    "/www/luci-static/resources/view/services/istoreos-sms.js",
    "/etc/init.d/istoreos_sms",
    "/usr/libexec/istoreos-sms/ensure-storage.sh",
    "/usr/share/luci/menu.d/istoreos-sms.json",
    "/usr/share/rpcd/acl.d/istoreos-sms.json",
}
for target in installed_targets:
    assert target in installer, f"installer target missing: {target}"
    assert target in uninstaller, f"uninstaller target missing: {target}"

view = read("htdocs/luci-static/resources/view/services/istoreos-sms.js")
ensure = read("root/usr/libexec/istoreos-sms/ensure-storage.sh")
for source in (view, ensure, read("README.md")):
    assert "AT+CNMI=2,1,0,0,0" in source
assert "'-j', 'recv'" in view
assert "innerHTML" not in view
assert "rm -f /tmp/luci-*" not in installer

print("repository validation: PASS")
