'use strict';
'require view';
'require fs';
'require ui';

// Paths are fixed rather than derived from the dashboard's env file, so the ACL
// can name them exactly and the QWeather key never has to be readable here.
var CONF  = '/root/kindle-dash/dash.conf';
var NOTES = '/root/kindle-dash/notes.txt';
var WATCH = '/root/kindle-dash/watch.txt';
var SERVE = '/root/kindle-dash/serve-dir';
var BUILT = '/root/kindle-dash/last-build';
var PAGES = '/root/kindle-dash/pages';
var BUILD = '/root/kindle-dash/build.sh';

function readOr(path, fallback) {
	return fs.read(path).then(function (s) {
		return (s === null || s === undefined) ? fallback : s;
	}).catch(function () {
		return fallback;
	});
}

// dash.conf is a flat KEY=value file with comments. Parsed and rewritten in
// place so hand-written comments survive a save from here.
function confGet(text, key, fallback) {
	var re = new RegExp('^' + key + '=(.*)$', 'm');
	var m = String(text || '').match(re);
	return m ? m[1].trim() : fallback;
}

function confSet(text, key, value) {
	text = String(text || '');
	var re = new RegExp('^' + key + '=.*$', 'm');
	if (re.test(text)) return text.replace(re, key + '=' + value);
	return text.replace(/\s*$/, '') + '\n' + key + '=' + value + '\n';
}

function css() {
	// Themes only indent a section's own first heading; every other child of
	// .cbi-section is flush against the card edge (Argon sets padding:0 on it).
	// .kd-body supplies the gutter the theme does not, and matches the 1.25rem
	// the heading already uses so the two line up.
	return '' +
	'.kd-body{padding:0 1.25rem 1.25rem;box-sizing:border-box}' +
	'.kd-body>*:last-child{margin-bottom:0}' +
	'.kd-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:16px;margin:0}' +
	'.kd-prev{text-align:center;font-size:12px;opacity:.75}' +
	'.kd-prev img{width:100%;max-width:250px;border:1px solid rgba(128,128,128,.4);background:#fff;display:block;margin:0 auto 6px}' +
	'.kd-hint{font-size:12px;opacity:.7;margin:0 0 10px;line-height:1.7}' +
	'.kd-out:not(:empty){white-space:pre-wrap;font-family:monospace;font-size:12px;margin:0 0 1.25rem;padding:0 1.25rem}' +
	'.kd-f{display:flex;flex-wrap:wrap;gap:18px;align-items:flex-end;margin-bottom:10px}' +
	'.kd-f label{display:block;font-size:12px;opacity:.75;margin-bottom:4px}' +
	'.kd-f>div{max-width:100%}' +
	'.kd-calc{font-size:12px;opacity:.85;margin-top:8px}' +
	'.kd-in{box-sizing:border-box;max-width:100%}' +
	'.kd-area{box-sizing:border-box;width:100%;max-width:100%;display:block}';
}

function input(value, width) {
	return E('input', {
		'type': 'text',
		'class': 'cbi-input-text kd-in',
		'value': value,
		'spellcheck': 'false',
		'style': 'width:' + (width || '160px') + ';font-family:monospace'
	});
}

function area(value, rows) {
	return E('textarea', {
		'class': 'cbi-input-textarea kd-area',
		'rows': rows,
		'spellcheck': 'false',
		'style': 'font-family:monospace'
	}, [ value ]);
}

// One card: a heading the theme indents itself, plus a padded body for the rest.
function section(title, children) {
	return E('div', { 'class': 'cbi-section' }, [
		E('h3', {}, title),
		E('div', { 'class': 'kd-body' }, children)
	]);
}

function previews(serveDir, total) {
	// serveDir is a filesystem path under /www; the browser sees it without that prefix.
	var base = String(serveDir || '').trim().replace(/^\/www/, '');
	if (!base) return E('div', { 'class': 'kd-hint' }, _('尚未构建，先点“保存并重建”。'));

	var n = parseInt(total, 10);
	if (!(n > 0)) n = 3;

	var bust = '?t=' + Date.now();
	var cards = [];
	for (var i = 1; i <= n; i++) {
		cards.push(E('div', { 'class': 'kd-prev' }, [
			E('img', { 'src': base + '/page-' + i + '.png' + bust, 'alt': 'page ' + i }),
			E('div', {}, _('第 ') + i + _(' 页'))
		]));
	}
	return E('div', { 'class': 'kd-grid' }, cards);
}

return view.extend({
	load: function () {
		return Promise.all([
			readOr(CONF, ''),
			readOr(NOTES, '# 备忘\n'),
			readOr(WATCH, ''),
			readOr(SERVE, ''),
			readOr(BUILT, ''),
			readOr(PAGES, '')
		]);
	},

	render: function (data) {
		var conf = data[0], notes = data[1], watch = data[2];
		var serveDir = data[3], builtAt = data[4], builtPages = data[5];

		var seqIn   = input(confGet(conf, 'SEQ', '1 2 3'), '220px');
		var wakeIn  = input(confGet(conf, 'WAKE_MINUTES', '9 24 39 54'), '260px');
		var specIn  = input(confGet(conf, 'PAGE_SPECS', '1:fetch.py 2:status.py 3:notes.py'), '420px');
		var notesArea = area(notes, 12);
		var watchArea = area(watch, 5);

		var calc = E('div', { 'class': 'kd-calc' });
		var sched = E('div', { 'class': 'kd-hint' });

		// build.sh rewrites the cron schedule to two minutes before every wake,
		// so the build times are not a constant that can be written into the
		// hint: they follow whatever is typed above.
		function buildTimes(wakes) {
			var seen = {}, out = [];
			wakes.forEach(function (w) {
				var m = (parseInt(w, 10) + 58) % 60;
				if (!seen[m]) { seen[m] = true; out.push(m); }
			});
			return out.sort(function (a, b) { return a - b; }).map(function (m) {
				return ':' + (m < 10 ? '0' : '') + m;
			});
		}

		function recalc() {
			var wakes = wakeIn.value.trim().split(/\s+/).filter(function (t) { return /^\d+$/.test(t); });
			var seq = seqIn.value.trim().split(/\s+/).filter(function (t) { return /^\d+$/.test(t); });
			var perHour = wakes.length || 0;
			var txt = _('每小时唤醒 ') + perHour + _(' 次');
			if (perHour > 0 && seq.length > 0) {
				var cycleMin = Math.round(seq.length * 60 / perHour);
				txt += _('，轮完一遍 ') + cycleMin + _(' 分钟');
				var counts = {};
				seq.forEach(function (p) { counts[p] = (counts[p] || 0) + 1; });
				var share = Object.keys(counts).sort().map(function (p) {
					return _('第') + p + _('页 ') + Math.round(counts[p] * 100 / seq.length) + '%';
				}).join(' · ');
				txt += '  (' + share + ')';
			}
			if (perHour > 4) txt += _('  —— 比默认更频繁，会更耗电');
			calc.textContent = txt;

			sched.textContent = wakes.length
				? _('保存并重建会把服务端的构建时刻改成 ') + buildTimes(wakes).join(' ') +
				  _('，也就是每次唤醒前两分钟，所以图总是新的。')
				: _('唤醒时刻为空时设备按固定间隔 INTERVAL 醒，相位会和服务端构建错开。');
		}
		seqIn.addEventListener('input', recalc);
		wakeIn.addEventListener('input', recalc);
		recalc();

		var output = E('div', { 'class': 'kd-out' });
		var previewBox = E('div', {}, previews(serveDir, builtPages));

		function save(thenBuild) {
			output.textContent = '';
			var next = conf;
			next = confSet(next, 'SEQ', seqIn.value.trim());
			next = confSet(next, 'WAKE_MINUTES', wakeIn.value.trim());
			next = confSet(next, 'PAGE_SPECS', specIn.value.trim());

			return fs.write(CONF, next)
				.then(function () { conf = next; return fs.write(NOTES, notesArea.value); })
				.then(function () { return fs.write(WATCH, watchArea.value); })
				.then(function () {
					if (!thenBuild) {
						ui.addNotification(null, E('p', _('已保存。下次构建时生效。')), 'info');
						return;
					}
					ui.showModal(_('正在重建'), [ E('p', { 'class': 'spinning' }, _('渲染所有页面…')) ]);
					return fs.exec(BUILD).then(function (res) {
						ui.hideModal();
						var txt = (res.stdout || '') + (res.stderr || '');
						output.textContent = txt.trim() || _('构建完成，无输出。');
						if (res.code !== 0) {
							ui.addNotification(null, E('p', _('构建失败，退出码 ') + res.code), 'error');
						} else {
							ui.addNotification(null, E('p', _('已重建。设备下次唤醒生效。')), 'info');
						}
						return Promise.all([ readOr(SERVE, ''), readOr(PAGES, '') ])
							.then(function (r) {
								previewBox.innerHTML = '';
								previewBox.appendChild(previews(r[0], r[1]));
							});
					});
				})
				.catch(function (err) {
					ui.hideModal();
					ui.addNotification(null, E('p', _('出错：') + err.message), 'error');
				});
		}

		return E('div', { 'class': 'cbi-map' }, [
			E('style', {}, css()),
			E('h2', {}, _('Kindle 看板')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Kindle 每次唤醒时从本机取配置和图，所以这里改完不需要插 USB，下次唤醒即生效。')),

			section(_('轮播与刷新'), [
				E('div', { 'class': 'kd-f' }, [
					E('div', {}, [ E('label', {}, _('页面顺序')), seqIn ]),
					E('div', {}, [ E('label', {}, _('唤醒时刻（每小时第几分钟）')), wakeIn ])
				]),
				E('div', { 'class': 'kd-hint' },
					_('顺序里重复某一页就等于加权，例如 1 2 1 3 让第 1 页出现的频率是其他页的两倍。')),
				sched,
				calc
			]),

			section(_('备忘内容'), [
				E('div', { 'class': 'kd-hint' }, [
					_('待办：- [ ] 未完成　/　- [x] 已完成（打勾的整行加删除线并降灰）'),
					E('br'),
					_('第一个 # 行是页面标题，之后的 # 行是页内小标题。'),
					E('br'),
					_('行首的 - 或 * 会被去掉；用 | 分成左右两列，例如：续签域名 | 11-20')
				]),
				notesArea
			]),

			section(_('系统状态页要探测的服务'), [
				E('div', { 'class': 'kd-hint' }, [
					_('每行一条，推荐用竖线分隔：名称 | https://example.com/'),
					E('br'),
					_('也可以用空格，从最后一个空格切分，所以名称里可以有空格。'),
					E('br'),
					_('只写 URL 则自动用主机名当名称。浏览器输入框打不出 Tab，所以不要用 Tab。')
				]),
				watchArea
			]),

			section(_('页面组成'), [
				E('div', { 'class': 'kd-hint' }, [
					_('格式为「页号:生成器」，页号必须从 1 开始连续。生成器是 /root/kindle-dash/ 下的 Python 文件，'),
					E('br'),
					_('不存在的会被跳过。加一页需要先在服务器上放一个新的生成器脚本。')
				]),
				specIn
			]),

			E('div', { 'class': 'cbi-page-actions' }, [
				E('button', {
					'class': 'cbi-button cbi-button-save',
					'click': ui.createHandlerFn(this, function () { return save(false); })
				}, _('保存')),
				' ',
				E('button', {
					'class': 'cbi-button cbi-button-apply',
					'click': ui.createHandlerFn(this, function () { return save(true); })
				}, _('保存并重建'))
			]),

			output,

			section(_('当前页面'), [
				E('div', { 'class': 'kd-hint' },
					_('最后构建：') + (String(builtAt).trim() || _('未知'))),
				previewBox
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
