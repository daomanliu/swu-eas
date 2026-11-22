#!/usr/bin/env node
/**
 * 从已登录的 Edge 拉取教务课表，按学期生成 App 数据
 *
 * 用法：
 *   node tools/sync-timetable.mjs --all                 # 抓所有有数据的学期（推荐）
 *   node tools/sync-timetable.mjs                       # 只抓当前学期
 *   node tools/sync-timetable.mjs --xn=2025 --xq=12     # 抓指定学期
 *   node tools/sync-timetable.mjs --xn=2025 --xq=3 --start=2025-09-01
 *
 * xqm 编码：3=第 1 学期，12=第 2 学期，16=第 3 学期（小学期）
 */
import { writeFile, mkdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';

const ROOT = path.resolve(import.meta.dirname, '..');
const RF_DIR = path.join(ROOT, 'entry/src/main/resources/rawfile');
const INDEX_FILE = path.join(RF_DIR, 'semesters.json');
const EDGE_UDD = path.join(process.env.LOCALAPPDATA || os.homedir(), 'Microsoft/Edge/User Data');

const args = process.argv.slice(2);
const arg = (k, d) => (args.find(a => a.startsWith('--' + k + '=')) || '').split('=')[1] || d;
const SYNC_ALL = args.includes('--all');

const XQ_LABEL = { '3': '1', '12': '2', '16': '3' };

/** 页面里执行：调教务系统接口，自动带 cookie */
const extractExpr = (xn, xq) => `
(async () => {
  const res = await fetch('/jwglxt/kbcx/xskbcx_cxXsgrkb.html?gnmkdm=N253508', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8',
      'X-Requested-With': 'XMLHttpRequest'
    },
    body: 'xnm=${xn}&xqm=${xq}&kzlx=ck&xsdm=&kclbdm=&kclxdm=',
    credentials: 'include'
  });
  const text = await res.text();
  if (res.status === 901) return JSON.stringify({ error: 'SESSION_EXPIRED' });
  if (!res.ok) return JSON.stringify({ error: 'HTTP ' + res.status });
  try {
    const j = JSON.parse(text);
    return JSON.stringify({ xsxx: j.xsxx || {}, kbList: j.kbList || [], sjkList: j.sjkList || [] });
  } catch (e) {
    return JSON.stringify({ error: 'NOT_JSON' });
  }
})()
`;

class Cdp {
  constructor(ws) {
    this.ws = ws;
    this.seq = 0;
    this.pending = new Map();
    ws.addEventListener('message', ev => {
      const msg = JSON.parse(typeof ev.data === 'string' ? ev.data : String(ev.data));
      const p = msg.id && this.pending.get(msg.id);
      if (!p) return;
      this.pending.delete(msg.id);
      msg.error ? p.reject(new Error(JSON.stringify(msg.error))) : p.resolve(msg.result);
    });
  }
  static async open(url) {
    const ws = new WebSocket(url);
    await new Promise((res, rej) => {
      ws.addEventListener('open', res, { once: true });
      ws.addEventListener('error', () => rej(new Error('WebSocket 连接失败：' + url)), { once: true });
    });
    return new Cdp(ws);
  }
  send(method, params = {}, sessionId) {
    const id = ++this.seq;
    const msg = { id, method, params };
    if (sessionId) msg.sessionId = sessionId;
    this.ws.send(JSON.stringify(msg));
    return new Promise((resolve, reject) => this.pending.set(id, { resolve, reject }));
  }
  close() { try { this.ws.close(); } catch {} }
}

async function browserWsUrl() {
  const file = path.join(EDGE_UDD, 'DevToolsActivePort');
  let text;
  try {
    text = await readFile(file, 'utf8');
  } catch {
    throw new Error('读不到 ' + file + '\n请在 Edge 打开 edge://inspect → 远程调试 → 勾选「允许对此浏览器实例进行远程调试」。');
  }
  const [port, wsPath] = text.split(/\r?\n/).filter(Boolean);
  return `ws://127.0.0.1:${port}${wsPath}`;
}

function parseWeeks(zcd) {
  const out = new Set();
  const s = String(zcd || '').replace(/[第周\s]/g, '');
  for (const part of s.split(/[,，]/)) {
    if (!part) continue;
    const m = part.match(/^(\d+)-(\d+)$/);
    if (m) { for (let i = +m[1]; i <= +m[2]; i++) out.add(i); continue; }
    const n = part.match(/^(\d+)$/);
    if (n) out.add(+n[1]);
  }
  return [...out].sort((a, b) => a - b);
}

function parsePeriods(item) {
  const raw = String(item.jcor || item.jc || '').replace(/[节\s]/g, '');
  const m = raw.match(/^(\d+)-(\d+)$/) || raw.match(/^(\d+)$/);
  if (!m) return null;
  return { start: +m[1], end: m[2] ? +m[2] : +m[1] };
}

function placeOf(item) {
  const cdmc = String(item.cdmc || '').trim();
  if (!cdmc || cdmc === '未排地点' || cdmc === '未安排') return cdmc || '未排地点';
  const campus = String(item.xqmc || '').trim();
  return campus ? `${campus} ${cdmc}` : cdmc;
}

function normalize(kbList, sjkList) {
  const byKey = new Map();
  const courses = [];
  for (const item of kbList) {
    const p = parsePeriods(item);
    if (!p) continue;
    const weekday = Number(item.xqj);
    if (!weekday) continue;
    const weeks = parseWeeks(item.zcd);
    if (!weeks.length) continue;
    const name = String(item.kcmc || '').trim();
    const teacher = String(item.xm || '').trim() || '—';
    const key = [name, weekday, p.start, p.end, item.cdmc].join('|');

    const existing = byKey.get(key);
    if (existing) {
      for (const w of weeks) if (existing.weeks.indexOf(w) < 0) existing.weeks.push(w);
      existing.weeks.sort((a, b) => a - b);
      if (existing.teacher.indexOf(teacher) < 0 && teacher !== '—') {
        existing.teacher = existing.teacher === '—' ? teacher : existing.teacher + ' / ' + teacher;
      }
      continue;
    }

    const exam = String(item.khfsmc || '').trim();
    const note = [String(item.kcxszc || '').trim(), exam && exam !== '未安排' ? exam : ''].filter(Boolean).join(' · ');

    const course = {
      id: String(item.jxb_id || '').slice(0, 12) || key.slice(0, 12),
      name, teacher,
      location: placeOf(item),
      weekday, start: p.start, end: p.end,
      weeks,
      practice: String(item.xslxbj || '') === '◆',
      note,
      credit: String(item.xf || '')
    };
    byKey.set(key, course);
    courses.push(course);
  }
  courses.sort((a, b) => a.weekday - b.weekday || a.start - b.start);

  const loose = sjkList.map((item, i) => ({
    id: 'loose_' + i,
    name: String(item.kcmc || '').trim(),
    teacher: String(item.jsxm || '').trim() || '—',
    weeks: String(item.qsjsz || '').trim(),
    note: String(item.qtkcgs || '').split('/').slice(1).join(' / ').trim()
  })).filter(x => x.name);

  return { courses, loose };
}

async function readIndex() {
  try {
    return JSON.parse(await readFile(INDEX_FILE, 'utf8'));
  } catch {
    return { default: '', items: [] };
  }
}

async function writeSemester(cdp, sessionId, xn, xq, startOverride, index) {
  const r = await cdp.send('Runtime.evaluate', {
    expression: extractExpr(xn, xq),
    awaitPromise: true,
    returnByValue: true
  }, sessionId);
  if (r.exceptionDetails) throw new Error('页面执行失败：' + JSON.stringify(r.exceptionDetails).slice(0, 200));
  const raw = typeof r.result.value === 'string' ? JSON.parse(r.result.value) : r.result.value;
  if (raw.error === 'SESSION_EXPIRED') throw new Error('教务系统登录已过期，请在 Edge 里重新登录后重试。');
  if (raw.error) throw new Error('教务系统返回 ' + raw.error);

  const { courses, loose } = normalize(raw.kbList || [], raw.sjkList || []);
  if (!courses.length) return null;

  const key = `${xn}_${xq}`;
  const xsxx = raw.xsxx || {};
  const label = `${xsxx.XNMC || xn} 学年第 ${XQ_LABEL[String(xq)] || xq} 学期`;
  const prev = index.items.find(i => i.key === key);
  const start = startOverride || (prev && prev.start) || '';

  const payload = {
    generatedAt: new Date().toISOString(),
    key, label,
    semester: label,
    semesterStart: start,
    major: xsxx.ZYMC || '',
    courseCount: courses.length,
    courses,
    loose
  };

  await writeFile(path.join(RF_DIR, `timetable_${key}.json`), JSON.stringify(payload, null, 2) + '\n', 'utf8');

  const item = { key, label, start, courseCount: courses.length };
  if (prev) Object.assign(prev, item);
  else index.items.push(item);

  return payload;
}

async function main() {
  await mkdir(RF_DIR, { recursive: true });
  const wsUrl = await browserWsUrl();
  console.log('[1/3] 连浏览器…');
  const cdp = await Cdp.open(wsUrl);
  const index = await readIndex();

  try {
    const { targetInfos } = await cdp.send('Target.getTargets');
    const pages = targetInfos.filter(t => t.type === 'page');
    const page = pages.find(t => t.url.includes('jw.swu.edu.cn'));
    if (!page) {
      throw new Error('没有 jw.swu.edu.cn 的标签页。当前打开：\n  ' + pages.map(t => t.url).slice(0, 6).join('\n  '));
    }
    const { sessionId } = await cdp.send('Target.attachToTarget', { targetId: page.targetId, flatten: true });
    console.log('[2/3] 目标页：' + page.title);

    let targets = [];
    if (SYNC_ALL) {
      const now = new Date();
      for (let y = now.getFullYear(); y >= now.getFullYear() - 2; y--) {
        targets.push({ xn: y, xq: 3 });
        targets.push({ xn: y, xq: 12 });
      }
    } else {
      const xn = Number(arg('xn', new Date().getFullYear()));
      const xq = Number(arg('xq', 3));
      targets = [{ xn, xq }];
    }

    const synced = [];
    for (const t of targets) {
      try {
        const out = await writeSemester(cdp, sessionId, t.xn, t.xq, arg('start', ''), index);
        if (out) {
          synced.push(out);
          console.log(`   ✓ ${out.label}  ${out.courses.length} 门`);
        } else {
          console.log(`   · ${t.xn}-${t.xq} 无课表数据，跳过`);
        }
      } catch (e) {
        if (String(e.message).includes('登录已过期')) throw e;
        console.log(`   · ${t.xn}-${t.xq} 失败：${e.message.slice(0, 60)}`);
      }
    }

    if (!synced.length) throw new Error('没有抓到任何学期的课表。');

    index.items.sort((a, b) => {
      const ay = Number(a.key.split('_')[0]);
      const by = Number(b.key.split('_')[0]);
      if (ay !== by) return by - ay;
      return Number(b.key.split('_')[1]) - Number(a.key.split('_')[1]);
    });
    // 默认学期按"今天"判断：9 月-次年 1 月=第 1 学期，2-8 月=第 2 学期
    const now = new Date();
    const m = now.getMonth() + 1;
    const curXn = m >= 9 ? now.getFullYear() : (m <= 1 ? now.getFullYear() - 1 : now.getFullYear() - 1);
    const curXq = (m >= 9 || m <= 1) ? 3 : 12;
    const curKey = `${curXn}_${curXq}`;
    index.default = index.items.some(i => i.key === curKey) ? curKey : index.items[0].key;
    await writeFile(INDEX_FILE, JSON.stringify(index, null, 2) + '\n', 'utf8');

    console.log(`[3/3] 已写入 ${synced.length} 个学期，默认 ${index.default}`);
    console.log('      索引：entry/src/main/resources/rawfile/semesters.json');
  } finally {
    cdp.close();
  }
}

main().catch(e => {
  console.error('✗ ' + e.message);
  process.exitCode = 1;
});
