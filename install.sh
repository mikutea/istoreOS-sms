#!/bin/sh
set -eu

CTRL="/usr/lib/lua/luci/controller/sms.lua"
VIEW_DIR="/usr/lib/lua/luci/view/sms"
VIEW_FILE="$VIEW_DIR/page.htm"
TOTAL_STEPS=6

log_step() {
  printf '[%s/%s] %s\n' "$1" "$TOTAL_STEPS" "$2"
}

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "[ERROR] 请使用 root 权限运行此脚本 (sudo sh install.sh)" >&2
    exit 1
  fi
}

clear_runtime_residues() {
  rm -f /tmp/luci-indexcache /tmp/luci-modulecache /tmp/luci-* 2>/dev/null || true
  rm -f /tmp/sms_* 2>/dev/null || true
  rm -f /root/fix_sms_*.sh /root/repair_sms_*.sh /root/*sms*debug*.sh 2>/dev/null || true
  find /usr/libexec/sms -maxdepth 1 -type f -name '*.bak.*' -delete 2>/dev/null || true
  find /usr/lib/lua/luci/controller -maxdepth 1 -type f -name 'sms.lua.bak.*' -delete 2>/dev/null || true
}

write_controller() {
  mkdir -p "$(dirname "$CTRL")"
  cat >"$CTRL" <<'LUA'
module("luci.controller.sms", package.seeall)

function index()
  local fs = require "nixio.fs"
  if not fs.access("/usr/bin/sms_tool") then
    return
  end

  entry({"admin", "services", "sms"}, call("action_page"), _("短信"), 60).dependent = false
  entry({"admin", "services", "sms", "data"}, call("action_data")).leaf = true
end

function action_page()
  require("luci.template").render("sms/page")
end

local function shquote(s)
  if s == nil then return "''" end
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

function action_data()
  local http = require "luci.http"
  local sys  = require "luci.sys"
  local json = require "luci.jsonc"

  local dev = http.formvalue("dev") or "/dev/ttyUSB2"

  -- 只允许 /dev/xxx 形式，避免注入
  if not dev:match("^/dev/[%w%._%-/]+$") then
    http.status(400, "Bad Request")
    http.prepare_content("application/json")
    http.write(json.stringify({ ok=false, error="invalid dev" }))
    return
  end

  -- PDU 模式（失败也无所谓）
  sys.exec("sms_tool -d " .. shquote(dev) .. " at \"AT+CMGF=0\" >/dev/null 2>/dev/null")

  local raw = sys.exec("sms_tool -d " .. shquote(dev) .. " at \"AT+CMGL=4\" 2>/dev/null") or ""
  local entries = {}
  local cur_idx = nil

  for line in raw:gmatch("[^\r\n]+") do
    line = line:gsub("\r", "")
    local idx = line:match("^%+CMGL:%s*(%d+),")
    if idx then
      cur_idx = tonumber(idx)
    else
      local pdu = line:match("^([0-9A-Fa-f]+)$")
      if cur_idx and pdu and #pdu >= 20 then
        entries[#entries+1] = { idx = cur_idx, pdu = pdu:upper() }
        cur_idx = nil
      end
    end
  end

  http.prepare_content("application/json")
  http.write(json.stringify({ ok=true, dev=dev, entries=entries }))
end
LUA
}

write_view() {
  mkdir -p "$VIEW_DIR"
  cat >"$VIEW_FILE" <<'HTM'
<%+header%>

<style>
.sms-wrap{max-width:1100px;margin:0 auto;padding:18px 16px 40px;}
.sms-top{display:flex;gap:12px;align-items:center;justify-content:space-between;margin:8px 0 14px;}
.sms-title{font-size:22px;font-weight:600;opacity:.95;}
.sms-controls{display:flex;gap:10px;align-items:center;flex-wrap:wrap;}
.sms-controls input{min-width:220px}
.sms-btn{cursor:pointer;border:1px solid rgba(255,255,255,.18);background:rgba(255,255,255,.04);border-radius:10px;padding:8px 12px}
.sms-btn:hover{background:rgba(255,255,255,.08)}
.sms-muted{opacity:.7}
.sms-grid{display:flex;flex-direction:column;gap:10px;margin-top:12px}
.sms-card{border:1px solid rgba(255,255,255,.14);background:rgba(0,0,0,.18);border-radius:14px;padding:14px 14px}
.sms-head{display:flex;gap:10px;align-items:baseline;justify-content:space-between}
.sms-from{font-weight:600}
.sms-time{opacity:.7;font-size:12px}
.sms-body{white-space:pre-wrap;word-break:break-word;margin-top:8px;line-height:1.55}
.sms-error{border-color:rgba(255,80,80,.45);background:rgba(255,80,80,.08)}
</style>

<div class="sms-wrap">
  <div class="sms-top">
    <div class="sms-title">短信</div>
    <div class="sms-controls">
      <span class="sms-muted">设备</span>
      <input id="dev" class="cbi-input-text" value="/dev/ttyUSB2" />
      <button id="refresh" class="sms-btn">刷新</button>
    </div>
  </div>

  <div id="status" class="sms-muted"></div>
  <div id="list" class="sms-grid"></div>
</div>

<script type="text/javascript">
//<![CDATA[
(function() {
  const $ = (id) => document.getElementById(id);
  const statusEl = $("status");
  const listEl = $("list");
  const refreshBtn = $("refresh");
  const devEl = $("dev");

  function setStatus(s) { statusEl.textContent = s || ""; }
  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({ "&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&#39;" }[c]));
  }
  function hexToBytes(hex) {
    const out = new Uint8Array(hex.length / 2);
    for (let i=0, j=0; i<hex.length; i+=2, j++) out[j] = parseInt(hex.substr(i,2), 16);
    return out;
  }
  function swapBcd(byte) {
    const hi = byte >> 4, lo = byte & 0x0F;
    return lo*10 + hi;
  }
  function decodeAddress(bytes, digits, toa) {
    let s = "";
    for (let i=0;i<Math.ceil(digits/2);i++) {
      const b = bytes[i];
      const lo = b & 0x0F, hi = b >> 4;
      s += (lo === 0x0F ? "" : lo.toString(16));
      s += (hi === 0x0F ? "" : hi.toString(16));
    }
    s = s.substr(0, digits);
    if ((toa & 0xF0) === 0x90) s = "+" + s;
    return s;
  }

  // GSM 7-bit alphabets (basic + extension via ESC 0x1B)
  const GSM7 = [
    "@","£","$","¥","è","é","ù","ì","ò","Ç","\n","Ø","ø","\r","Å","å",
    "Δ","_","Φ","Γ","Λ","Ω","Π","Ψ","Σ","Θ","Ξ","\u001B","Æ","æ","ß","É",
    " ","!","\"","#","¤","%","&","'","(",")","*","+",",","-",".","/",
    "0","1","2","3","4","5","6","7","8","9",":",";","<","=",">","?",
    "¡","A","B","C","D","E","F","G","H","I","J","K","L","M","N","O",
    "P","Q","R","S","T","U","V","W","X","Y","Z","Ä","Ö","Ñ","Ü","§",
    "¿","a","b","c","d","e","f","g","h","i","j","k","l","m","n","o",
    "p","q","r","s","t","u","v","w","x","y","z","ä","ö","ñ","ü","à"
  ];
  const GSM7_EXT = { 0x0A:"\f",0x14:"^",0x28:"{",0x29:"}",0x2F:"\\",0x3C:"[",0x3D:"~",0x3E:"]",0x40:"|",0x65:"€" };

  function unpackGsm7(bytes, septetCount, skipBits) {
    let out = "";
    let bitPos = skipBits; // UDH 造成的 bit 偏移
    for (let s=0; s<septetCount; s++) {
      let val = 0;
      for (let b=0; b<7; b++) {
        const totalBit = bitPos + b;
        const byteIndex = Math.floor(totalBit / 8);
        const bitIndex  = totalBit % 8;
        const bit = (bytes[byteIndex] >> bitIndex) & 1;
        val |= (bit << b);
      }
      bitPos += 7;

      if (val === 0x1B) {
        // escape
        let next = 0;
        for (let b=0; b<7; b++) {
          const totalBit = bitPos + b;
          const byteIndex = Math.floor(totalBit / 8);
          const bitIndex  = totalBit % 8;
          const bit = (bytes[byteIndex] >> bitIndex) & 1;
          next |= (bit << b);
        }
        bitPos += 7;
        s++;
        out += (GSM7_EXT[next] != null) ? GSM7_EXT[next] : "";
      } else {
        out += GSM7[val] != null ? GSM7[val] : "";
      }
    }
    return out;
  }

  function parsePdu(pduHex) {
    const b = hexToBytes(pduHex);
    let p = 0;

    const smscLen = b[p]; p += 1 + smscLen;
    if (p >= b.length) return null;

    const pduType = b[p++];
    const udhi = (pduType & 0x40) !== 0;

    const oaDigits = b[p++];
    const oaToa = b[p++];
    const oaBytesLen = Math.ceil(oaDigits / 2);
    const oaBytes = b.slice(p, p + oaBytesLen); p += oaBytesLen;
    const sender = decodeAddress(oaBytes, oaDigits, oaToa);

    p++; // PID
    const dcs = b[p++];

    const scts = b.slice(p, p+7); p += 7;
    const yy = swapBcd(scts[0]);
    const year = (yy >= 70 ? 1900 + yy : 2000 + yy);
    const month = swapBcd(scts[1]);
    const day = swapBcd(scts[2]);
    const hour = swapBcd(scts[3]);
    const minute = swapBcd(scts[4]);
    const second = swapBcd(scts[5]);
    const timeStr = `${year}-${String(month).padStart(2,'0')}-${String(day).padStart(2,'0')} ${String(hour).padStart(2,'0')}:${String(minute).padStart(2,'0')}:${String(second).padStart(2,'0')}`;
    const ts = new Date(year, month-1, day, hour, minute, second).getTime();

    const udl = b[p++];
    let ud = b.slice(p);

    // UCS2/8bit: udl=bytes；GSM7: udl=septets
    let packed;
    if ((dcs & 0x0C) === 0x08 || (dcs & 0x0C) === 0x04) {
      packed = ud.slice(0, udl);
    } else {
      packed = ud.slice(0, Math.ceil((udl * 7) / 8));
    }

    // UDH 解析（用于长短信拼接）
    let concat = null;
    let payload = packed;
    let skipBits = 0;

    if (udhi && payload.length > 0) {
      const udhl = payload[0];
      const udh = payload.slice(1, 1 + udhl);
      payload = payload.slice(1 + udhl);

      for (let x=0; x<udh.length; ) {
        const iei = udh[x++], iedl = udh[x++];
        const data = udh.slice(x, x + iedl);
        x += iedl;

        // 8-bit ref: 00 03 ref total seq
        if (iei === 0x00 && iedl === 0x03) concat = { ref: data[0], total: data[1], seq: data[2] };
        // 16-bit ref: 08 04 refHi refLo total seq
        if (iei === 0x08 && iedl === 0x04) concat = { ref: (data[0]<<8)|data[1], total: data[2], seq: data[3] };
      }

      // GSM7 情况下，UDH 会造成 bit 偏移
      skipBits = ((1 + udhl) * 8) % 7;
    }

    // 解码正文
    let text = "";
    if ((dcs & 0x0C) === 0x08) {
      // UCS2 / UTF-16BE
      const codes = [];
      for (let i=0; i+1<payload.length; i+=2) codes.push((payload[i]<<8) | payload[i+1]);
      text = String.fromCharCode.apply(null, codes);
    } else if ((dcs & 0x0C) === 0x04) {
      // 8-bit
      try { text = new TextDecoder("iso-8859-1").decode(payload); }
      catch(e) { text = Array.from(payload).map(b=>String.fromCharCode(b)).join(""); }
    } else {
      // GSM 7-bit
      text = unpackGsm7(packed, udl, udhi ? skipBits : 0);
      // 如果有 UDH，unpack 后 text 里会包含 UDH 造成的“脏字符”的概率很低（按 skipBits 处理基本可用）
      // 真要极致严格，需要按 03.40 进一步处理，这里以可用为主
      if (udhi) {
        // 去掉可能的前导不可见字符
        text = text.replace(/^\u0000+/, "");
      }
    }

    return { sender, timeStr, ts, text, concat };
  }

  function buildMessages(entries) {
    const groups = new Map();
    const out = [];

    for (const it of entries) {
      const p = parsePdu(it.pdu);
      if (!p) continue;

      if (p.concat && p.concat.total > 1) {
        const key = `${p.sender}|${p.concat.ref}|${p.concat.total}`;
        if (!groups.has(key)) groups.set(key, { sender:p.sender, total:p.concat.total, ts:p.ts, timeStr:p.timeStr, parts:[] });
        const g = groups.get(key);
        g.ts = Math.min(g.ts, p.ts);
        g.parts.push({ seq:p.concat.seq, text:p.text });
      } else {
        out.push({ sender:p.sender, ts:p.ts, timeStr:p.timeStr, text:p.text });
      }
    }

    for (const g of groups.values()) {
      g.parts.sort((a,b)=>a.seq-b.seq); // 关键：按 seq 拼接，和手机一致 
      out.push({ sender:g.sender, ts:g.ts, timeStr:g.timeStr, text:g.parts.map(x=>x.text).join("") });
    }

    out.sort((a,b)=>b.ts-a.ts);
    return out;
  }

  function render(list) {
    listEl.innerHTML = "";
    if (!list.length) {
      listEl.innerHTML = '<div class="sms-muted">没有短信</div>';
      return;
    }
    for (const m of list) {
      const card = document.createElement("div");
      card.className = "sms-card";
      card.innerHTML = `
        <div class="sms-head">
          <div class="sms-from">${escapeHtml(m.sender || "未知")}</div>
          <div class="sms-time">${escapeHtml(m.timeStr || "")}</div>
        </div>
        <div class="sms-body">${escapeHtml(m.text || "")}</div>
      `;
      listEl.appendChild(card);
    }
  }

  function renderError(err) {
    listEl.innerHTML = "";
    const card = document.createElement("div");
    card.className = "sms-card sms-error";
    card.innerHTML = `<div class="sms-from">错误</div><div class="sms-body">${escapeHtml(String(err || "unknown"))}</div>`;
    listEl.appendChild(card);
  }

  async function load() {
    setStatus("读取中…");
    refreshBtn.disabled = true;

    const dev = devEl.value.trim() || "/dev/ttyUSB2";
    const url = window.location.pathname.replace(/\/$/, "") + "/data?dev=" + encodeURIComponent(dev);

    try {
      const res = await fetch(url, { cache: "no-store" });
      const j = await res.json();
      if (!j || !j.ok) throw new Error((j && j.error) || "backend error");
      const msgs = buildMessages(j.entries || []);
      render(msgs);
      setStatus(`共 ${msgs.length} 条（原始分片 ${(j.entries || []).length} 条）`);
    } catch (e) {
      setStatus("");
      renderError(e);
    } finally {
      refreshBtn.disabled = false;
    }
  }

  refreshBtn.addEventListener("click", load);
  load();
})();
 //]]>
</script>

<%+footer%>
HTM
}

restart_services() {
  /etc/init.d/uhttpd restart >/dev/null 2>&1 || true
  /etc/init.d/rpcd restart  >/dev/null 2>&1 || true
}

require_root
umask 022

log_step 1 "清理 LuCI 缓存及残留文件..."
clear_runtime_residues

log_step 2 "写入 LuCI 控制器 ($CTRL)..."
write_controller

log_step 3 "写入 LuCI 前端页面 ($VIEW_FILE)..."
write_view

log_step 4 "再次清理 LuCI 缓存..."
rm -f /tmp/luci-indexcache /tmp/luci-modulecache /tmp/luci-* 2>/dev/null || true

log_step 5 "重启 uhttpd / rpcd 服务..."
restart_services

log_step 6 "完成。LuCI -> 服务 -> 短信 (必要时 Ctrl+F5 强制刷新)。"

if ! command -v sms_tool >/dev/null 2>&1; then
  echo "[WARN] 系统未检测到 sms_tool，可按需安装后再刷新页面。"
fi
