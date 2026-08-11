'use strict';
'require view';
'require fs';
'require uci';
'require ui';
'require dom';

var CONFIG = 'istoreos_sms';
var SECTION = 'main';
var HEALTHY_CNMI = '2,1,0,0,0';

function validDevice(device) {
	return /^\/dev\/(ttyUSB|ttyACM|ttyS|mhi_|wwan)[A-Za-z0-9._-]*$/.test(device || '');
}

function command(args) {
	return fs.exec('/usr/bin/sms_tool', args).then(function(res) {
		if (!res || res.code !== 0) {
			var detail = res && (res.stderr || res.stdout);
			throw new Error((detail || 'sms_tool 执行失败').trim());
		}
		return (res.stdout || '').trim();
	});
}

function parseStatus(output) {
	var used = output.match(/used\s*:?\s*(\d+)/i);
	var total = output.match(/total\s*:?\s*(\d+)/i);
	return {
		used: used ? Number(used[1]) : null,
		total: total ? Number(total[1]) : null,
		raw: output
	};
}

function parseCnmi(output) {
	var match = output.match(/\+CNMI:\s*([0-9]+\s*,\s*[0-9]+\s*,\s*[0-9]+\s*,\s*[0-9]+\s*,\s*[0-9]+)/i);
	var value = match ? match[1].replace(/\s+/g, '') : '';
	return {
		value: value,
		healthy: value === HEALTHY_CNMI,
		raw: output
	};
}

function normalizeMessage(item) {
	return {
		index: item.index,
		sender: String(item.sender || '未知号码'),
		timestamp: String(item.timestamp || ''),
		content: String(item.content || ''),
		reference: item.reference,
		part: Number(item.part || 0),
		total: Number(item.total || 0),
		segments: 1
	};
}

function mergeMessages(items) {
	var groups = {};
	var messages = [];

	(items || []).forEach(function(raw) {
		var item = normalizeMessage(raw);
		if (item.total > 1 && item.reference != null) {
			var day = item.timestamp.substring(0, 10);
			var key = [ item.sender, item.reference, item.total, day ].join('|');
			if (!groups[key]) {
				groups[key] = {
					sender: item.sender,
					timestamp: item.timestamp,
					total: item.total,
					parts: {},
					indexes: []
				};
			}
			groups[key].parts[item.part] = item.content;
			groups[key].indexes.push(item.index);
			if (item.timestamp > groups[key].timestamp)
				groups[key].timestamp = item.timestamp;
		}
		else {
			messages.push(item);
		}
	});

	Object.keys(groups).forEach(function(key) {
		var group = groups[key];
		var content = [];
		for (var part = 1; part <= group.total; part++)
			content.push(group.parts[part] != null ? group.parts[part] : '[缺少第 ' + part + ' 段]');

		messages.push({
			index: group.indexes.join('-'),
			sender: group.sender,
			timestamp: group.timestamp,
			content: content.join(''),
			segments: Object.keys(group.parts).length,
			total: group.total
		});
	});

	messages.sort(function(a, b) {
		return String(b.timestamp).localeCompare(String(a.timestamp));
	});
	return messages;
}

function parseMessages(output) {
	var parsed;
	try {
		parsed = JSON.parse(output);
	}
	catch (err) {
		throw new Error('sms_tool 返回的 JSON 无法解析：' + err.message);
	}
	if (!parsed || !Array.isArray(parsed.msg))
		throw new Error('sms_tool 返回内容缺少 msg 数组');
	return mergeMessages(parsed.msg);
}

return view.extend({
	load: function() {
		return uci.load(CONFIG);
	},

	render: function() {
		this.messages = [];
		this.device = uci.get(CONFIG, SECTION, 'device') || '/dev/ttyUSB2';
		this.storage = uci.get(CONFIG, SECTION, 'storage') || 'SM';
		this.autoRepair = uci.get(CONFIG, SECTION, 'auto_repair') !== '0';

		this.deviceInput = E('input', {
			'class': 'cbi-input-text',
			'type': 'text',
			'value': this.device,
			'placeholder': '/dev/ttyUSB3'
		});
		this.storageInput = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'SM', 'selected': this.storage === 'SM' ? '' : null }, [ 'SM（SIM）' ]),
			E('option', { 'value': 'ME', 'selected': this.storage === 'ME' ? '' : null }, [ 'ME（模块）' ]),
			E('option', { 'value': 'MT', 'selected': this.storage === 'MT' ? '' : null }, [ 'MT（组合）' ])
		]);
		this.autoRepairInput = E('input', {
			'type': 'checkbox',
			'checked': this.autoRepair ? '' : null
		});
		this.searchInput = E('input', {
			'class': 'cbi-input-text',
			'type': 'search',
			'placeholder': '搜索号码、时间或正文',
			'input': L.bind(this.renderMessages, this)
		});
		this.statusNode = E('div', { 'class': 'alert-message notice' }, [ '等待读取…' ]);
		this.countNode = E('span', { 'class': 'control-label' }, [ '0 条' ]);
		this.tableNode = E('div', {}, []);

		var node = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ '短信（iStoreOS-SMS）' ]),
			E('div', { 'class': 'cbi-map-descr' }, [
				'读取调制解调器存储中的短信，并检查是否因 CNMI 直推模式导致新短信没有入库。'
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, [ '连接设置' ]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ 'AT / 短信串口' ]),
					E('div', { 'class': 'cbi-value-field' }, [ this.deviceInput ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ '存储区' ]),
					E('div', { 'class': 'cbi-value-field' }, [ this.storageInput ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ '开机自检' ]),
					E('div', { 'class': 'cbi-value-field' }, [
						E('label', {}, [ this.autoRepairInput, ' 自动确保 CNMI=2,1,0,0,0' ])
					])
				]),
				E('div', { 'class': 'cbi-page-actions' }, [
					E('button', {
						'class': 'cbi-button cbi-button-save',
						'click': L.bind(this.handleSettingsSave, this)
					}, [ '保存设置' ]),
					' ',
					E('button', {
						'class': 'cbi-button cbi-button-apply',
						'click': L.bind(this.handleRepair, this)
					}, [ '一键修复接收模式' ])
				])
			]),
			this.statusNode,
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'style': 'display:flex;gap:1em;align-items:center;flex-wrap:wrap;margin-bottom:1em' }, [
					this.searchInput,
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'click': L.bind(this.refresh, this)
					}, [ '刷新短信' ]),
					this.countNode
				]),
				this.tableNode
			])
		]);

		window.setTimeout(L.bind(this.refresh, this), 0);
		return node;
	},

	readInputs: function() {
		var device = this.deviceInput.value.trim();
		var storage = this.storageInput.value;
		if (!validDevice(device))
			throw new Error('串口路径无效，仅允许常见的 /dev/ttyUSB、ttyACM、ttyS、mhi 或 wwan 设备');
		if ([ 'SM', 'ME', 'MT' ].indexOf(storage) < 0)
			throw new Error('存储区必须是 SM、ME 或 MT');
		return { device: device, storage: storage };
	},

	setStatus: function(text, level) {
		this.statusNode.className = 'alert-message ' + (level || 'notice');
		dom.content(this.statusNode, [ text ]);
	},

	refresh: function(ev) {
		if (ev)
			ev.preventDefault();

		var settings;
		try {
			settings = this.readInputs();
		}
		catch (err) {
			this.setStatus(err.message, 'error');
			return Promise.resolve();
		}

		this.device = settings.device;
		this.storage = settings.storage;
		this.setStatus('正在读取短信和接收模式…', 'notice');

		var status;
		return command([ '-s', this.storage, '-d', this.device, 'status' ])
			.then(function(output) {
				status = parseStatus(output);
				return command([ '-s', this.storage, '-d', this.device, '-f', '%Y-%m-%d %H:%M:%S', '-j', 'recv' ]);
			}.bind(this))
			.then(function(output) {
				this.messages = parseMessages(output);
				this.renderMessages();
				return command([ '-d', this.device, 'at', 'AT+CNMI?' ]);
			}.bind(this))
			.then(function(output) {
				var cnmi = parseCnmi(output);
				var usage = status.used != null && status.total != null ?
					('存储 ' + status.used + '/' + status.total + '；') : '';
				if (cnmi.healthy)
					this.setStatus(usage + 'CNMI=' + cnmi.value + '，新短信会写入存储区。', 'success');
				else
					this.setStatus(usage + 'CNMI=' + (cnmi.value || '无法识别') + '，可能导致短信不入库；请使用“一键修复接收模式”。', 'warning');
			}.bind(this))
			.catch(function(err) {
				this.setStatus(err.message || String(err), 'error');
			}.bind(this));
	},

	renderMessages: function() {
		var query = (this.searchInput.value || '').trim().toLowerCase();
		var filtered = this.messages.filter(function(message) {
			if (!query)
				return true;
			return [ message.sender, message.timestamp, message.content ].join('\n').toLowerCase().indexOf(query) >= 0;
		});

		dom.content(this.countNode, [ filtered.length + ' / ' + this.messages.length + ' 条' ]);
		if (!filtered.length) {
			dom.content(this.tableNode, [ E('em', {}, [ this.messages.length ? '没有匹配的短信' : '没有短信' ]) ]);
			return;
		}

		var rows = [ E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th' }, [ '时间' ]),
			E('th', { 'class': 'th' }, [ '号码' ]),
			E('th', { 'class': 'th' }, [ '内容' ])
		]) ];

		filtered.forEach(function(message) {
			var segmentInfo = message.total > 1 ?
				E('small', { 'style': 'display:block;opacity:.7;margin-top:.35em' }, [
					'长短信分片 ' + message.segments + '/' + message.total
				]) : null;
			rows.push(E('tr', { 'class': 'tr cbi-section-table-row' }, [
				E('td', { 'class': 'td', 'data-title': '时间' }, [ message.timestamp || '—' ]),
				E('td', { 'class': 'td', 'data-title': '号码' }, [ message.sender ]),
				E('td', { 'class': 'td', 'data-title': '内容', 'style': 'white-space:pre-wrap;word-break:break-word' },
					segmentInfo ? [ message.content, segmentInfo ] : [ message.content ])
			]));
		});

		dom.content(this.tableNode, [ E('table', { 'class': 'table cbi-section-table' }, rows) ]);
	},

	handleRepair: function(ev) {
		ev.preventDefault();
		var settings;
		try {
			settings = this.readInputs();
		}
		catch (err) {
			this.setStatus(err.message, 'error');
			return;
		}

		this.setStatus('正在设置 CNMI=2,1,0,0,0…', 'notice');
		return command([ '-d', settings.device, 'at', 'AT+CNMI=2,1,0,0,0' ])
			.then(function() {
				return command([ '-d', settings.device, 'at', 'AT+CNMI?' ]);
			})
			.then(function(output) {
				var cnmi = parseCnmi(output);
				if (!cnmi.healthy)
					throw new Error('命令已发送，但回读为 CNMI=' + (cnmi.value || '无法识别'));
				this.setStatus('修复成功：CNMI=' + cnmi.value + '。后续短信会写入存储区。', 'success');
			}.bind(this))
			.catch(function(err) {
				this.setStatus(err.message || String(err), 'error');
			}.bind(this));
	},

	handleSettingsSave: function(ev) {
		ev.preventDefault();
		var settings;
		try {
			settings = this.readInputs();
		}
		catch (err) {
			this.setStatus(err.message, 'error');
			return;
		}

		var enabled = this.autoRepairInput.checked;
		uci.set(CONFIG, SECTION, 'device', settings.device);
		uci.set(CONFIG, SECTION, 'storage', settings.storage);
		uci.set(CONFIG, SECTION, 'auto_repair', enabled ? '1' : '0');
		this.setStatus('正在保存设置…', 'notice');

		return uci.save()
			.then(function() { return uci.apply(); })
			.then(function() {
				return fs.exec('/etc/init.d/istoreos_sms', [ enabled ? 'enable' : 'disable' ]);
			})
			.then(function() {
				return fs.exec('/etc/init.d/istoreos_sms', [ enabled ? 'restart' : 'stop' ]);
			})
			.then(function() {
				this.setStatus('设置已保存。', 'success');
				return this.refresh();
			}.bind(this))
			.catch(function(err) {
				this.setStatus(err.message || String(err), 'error');
			}.bind(this));
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
