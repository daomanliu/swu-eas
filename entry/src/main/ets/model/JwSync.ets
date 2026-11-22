import { http } from '@kit.NetworkKit';
import { webview } from '@kit.ArkWeb';
import { Course, LooseCourse, TimetableSnapshot, Period, PERIODS } from './TimetableData';

const JW_HOST: string = 'https://jw.swu.edu.cn';
const KB_API: string = 'https://jw.swu.edu.cn/jwglxt/kbcx/xskbcx_cxXsgrkb.html?gnmkdm=N253508';

/** 教务接口返回的原始条目（只取用到的字段） */
interface ApiKbItem {
  kcmc: string;
  xm: string;
  cdmc: string;
  xqmc: string;
  xqj: string;
  jcor: string;
  jc: string;
  zcd: string;
  xslxbj: string;
  kcxszc: string;
  khfsmc: string;
  jxb_id: string;
  xf: string;
}

interface ApiSjkItem {
  kcmc: string;
  jsxm: string;
  qsjsz: string;
  qtkcgs: string;
}

interface ApiXsxx {
  XNMC: string;
  XQMMC: string;
  ZYMC: string;
}

interface ApiResp {
  xsxx: ApiXsxx;
  kbList: ApiKbItem[];
  sjkList: ApiSjkItem[];
}

/** 一条成绩 */
export interface GradeItem {
  term: string;
  name: string;
  score: string;
  gpa: string;
  credit: string;
  nature: string;
  teacher: string;
  examType: string;
}

/** 一场考试 */
export interface ExamItem {
  term: string;
  name: string;
  time: string;
  place: string;
  teacher: string;
  examName: string;
}

interface ApiGradeItem {
  kcmc: string;
  cj: string;
  jd: string;
  xf: string;
  kcxzmc: string;
  jsxm: string;
  ksxz: string;
}

interface ApiExamItem {
  kcmc: string;
  kssj: string;
  cdmc: string;
  cdxqmc: string;
  jsxx: string;
  ksmc: string;
}

interface ApiGradeResp {
  items: ApiGradeItem[];
}

interface ApiExamResp {
  items: ApiExamItem[];
}

export interface SyncedSemesterData {
  key: string;
  label: string;
  snapshot: TimetableSnapshot;
}

export class JwSync {
  /** 从 webview 里取教务域名的 cookie（http/https、带路径都试一遍并合并去重） */
  static cookie(): string {
    const urls: string[] = [
      'https://jw.swu.edu.cn/jwglxt/',
      'https://jw.swu.edu.cn/',
      'http://jw.swu.edu.cn/jwglxt/',
      'http://jw.swu.edu.cn/'
    ];
    const merged: string[] = [];
    for (let i: number = 0; i < urls.length; i++) {
      try {
        const c: string = webview.WebCookieManager.fetchCookieSync(urls[i]);
        if (c === '') {
          continue;
        }
        const parts: string[] = c.split(';');
        for (let j: number = 0; j < parts.length; j++) {
          const kv: string = parts[j].trim();
          if (kv === '') {
            continue;
          }
          const name: string = kv.split('=')[0];
          let dup: boolean = false;
          for (let k: number = 0; k < merged.length; k++) {
            if (merged[k].split('=')[0] === name) {
              dup = true;
              break;
            }
          }
          if (!dup) {
            merged.push(kv);
          }
        }
      } catch (err) {
        // 忽略单个 URL 的失败
      }
    }
    return merged.join('; ');
  }

  static isLoggedIn(c: string): boolean {
    return c.indexOf('JSESSIONID') >= 0;
  }

  private static parseWeeks(zcd: string): number[] {
    const out: number[] = [];
    const s: string = String(zcd === undefined || zcd === null ? '' : zcd).replace(/[第周\s]/g, '');
    const parts: string[] = s.split(/[,，]/);
    for (let i: number = 0; i < parts.length; i++) {
      const p: string = parts[i];
      if (p === '') {
        continue;
      }
      const m: RegExpMatchArray | null = p.match(/^(\d+)-(\d+)$/);
      if (m !== null) {
        const a: number = Number(m[1]);
        const b: number = Number(m[2]);
        for (let w: number = a; w <= b; w++) {
          out.push(w);
        }
        continue;
      }
      const n: RegExpMatchArray | null = p.match(/^(\d+)$/);
      if (n !== null) {
        out.push(Number(n[1]));
      }
    }
    const uniq: number[] = [];
    for (let i: number = 0; i < out.length; i++) {
      if (uniq.indexOf(out[i]) < 0) {
        uniq.push(out[i]);
      }
    }
    return uniq.sort((a: number, b: number) => a - b);
  }

  private static parsePeriods(it: ApiKbItem): Period | null {
    const raw: string = String(it.jcor !== undefined && it.jcor !== '' ? it.jcor : it.jc)
      .replace(/[节\s]/g, '');
    const m: RegExpMatchArray | null = raw.match(/^(\d+)-(\d+)$/);
    if (m !== null) {
      return { index: 0, start: m[1], end: m[2], group: '' };
    }
    const single: RegExpMatchArray | null = raw.match(/^(\d+)$/);
    if (single !== null) {
      return { index: 0, start: single[1], end: single[1], group: '' };
    }
    return null;
  }

  private static place(it: ApiKbItem): string {
    const cdmc: string = String(it.cdmc === undefined || it.cdmc === null ? '' : it.cdmc).trim();
    if (cdmc === '' || cdmc === '未排地点' || cdmc === '未安排') {
      return cdmc === '' ? '未排地点' : cdmc;
    }
    const campus: string = String(it.xqmc === undefined || it.xqmc === null ? '' : it.xqmc).trim();
    return campus === '' ? cdmc : `${campus} ${cdmc}`;
  }

  private static normalize(resp: ApiResp): Course[] {
    const kb: ApiKbItem[] = resp.kbList === undefined || resp.kbList === null ? [] : resp.kbList;
    const courses: Course[] = [];
    const keys: string[] = [];

    for (let i: number = 0; i < kb.length; i++) {
      const it: ApiKbItem = kb[i];
      const p: Period | null = JwSync.parsePeriods(it);
      if (p === null) {
        continue;
      }
      const day: number = Number(it.xqj);
      if (day === 0 || isNaN(day)) {
        continue;
      }
      const wk: number[] = JwSync.parseWeeks(it.zcd);
      if (wk.length === 0) {
        continue;
      }
      const name: string = String(it.kcmc === undefined ? '' : it.kcmc).trim();
      const teacher: string = String(it.xm === undefined || it.xm === null ? '' : it.xm).trim() || '—';
      const start: number = Number(p.start);
      const end: number = Number(p.end);
      const key: string = `${name}|${day}|${start}|${end}|${it.cdmc}`;

      const idx: number = keys.indexOf(key);
      if (idx >= 0) {
        const ex: Course = courses[idx];
        for (let k: number = 0; k < wk.length; k++) {
          if (ex.weeks.indexOf(wk[k]) < 0) {
            ex.weeks.push(wk[k]);
          }
        }
        ex.weeks.sort((a: number, b: number) => a - b);
        if (ex.teacher.indexOf(teacher) < 0 && teacher !== '—') {
          ex.teacher = ex.teacher === '—' ? teacher : `${ex.teacher} / ${teacher}`;
        }
        continue;
      }

      const exam: string = String(it.khfsmc === undefined || it.khfsmc === null ? '' : it.khfsmc).trim();
      const kcxszc: string = String(it.kcxszc === undefined || it.kcxszc === null ? '' : it.kcxszc).trim();
      const note: string = [kcxszc, exam !== '' && exam !== '未安排' ? exam : ''].filter((x: string) => x !== '').join(' · ');

      keys.push(key);
      courses.push({
        id: String(it.jxb_id === undefined ? key : it.jxb_id).slice(0, 12),
        name: name,
        teacher: teacher,
        location: JwSync.place(it),
        weekday: day,
        start: start,
        end: end,
        weeks: wk,
        practice: String(it.xslxbj === undefined ? '' : it.xslxbj) === '◆',
        note: note,
        credit: String(it.xf === undefined ? '' : it.xf)
      });
    }

    courses.sort((a: Course, b: Course) => a.weekday - b.weekday || a.start - b.start);
    return courses;
  }

  private static normalizeLoose(resp: ApiResp): LooseCourse[] {
    const sjk: ApiSjkItem[] = resp.sjkList === undefined || resp.sjkList === null ? [] : resp.sjkList;
    const loose: LooseCourse[] = [];
    for (let i: number = 0; i < sjk.length; i++) {
      const s: ApiSjkItem = sjk[i];
      const nm: string = String(s.kcmc === undefined ? '' : s.kcmc).trim();
      if (nm === '') {
        continue;
      }
      const raw: string = String(s.qtkcgs === undefined || s.qtkcgs === null ? '' : s.qtkcgs);
      const segs: string[] = raw.split('/');
      loose.push({
        id: `loose_${i}`,
        name: nm,
        teacher: String(s.jsxm === undefined || s.jsxm === null ? '' : s.jsxm).trim() || '—',
        weeks: String(s.qsjsz === undefined || s.qsjsz === null ? '' : s.qsjsz).trim(),
        note: segs.length > 1 ? segs.slice(1).join(' / ').trim() : ''
      });
    }
    return loose;
  }

  /** 拉一个学期；没有课表返回 null；登录过期抛异常 */
  static async fetchSemester(cookie: string, xn: number, xq: number): Promise<SyncedSemesterData | null> {
    const req: http.HttpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await req.request(KB_API, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8',
          'X-Requested-With': 'XMLHttpRequest',
          'Cookie': cookie
        },
        extraData: `xnm=${xn}&xqm=${xq}&kzlx=ck&xsdm=&kclbdm=&kclxdm=`,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: 20000
      });

      if (resp.responseCode === 901) {
        throw new Error('EXPIRED');
      }
      if (resp.responseCode !== 200) {
        return null;
      }

      const text: string = resp.result as string;
      const parsed: ApiResp = JSON.parse(text) as ApiResp;
      const courses: Course[] = JwSync.normalize(parsed);
      if (courses.length === 0) {
        return null;
      }
      const loose: LooseCourse[] = JwSync.normalizeLoose(parsed);
      const xsxx: ApiXsxx = parsed.xsxx;
      const xnName: string = xsxx === undefined || xsxx.XNMC === undefined ? String(xn) : xsxx.XNMC;
      const xqName: string = xq === 3 ? '1' : (xq === 12 ? '2' : '3');
      const label: string = `${xnName} 学年第 ${xqName} 学期`;

      return {
        key: `${xn}_${xq}`,
        label: label,
        snapshot: {
          generatedAt: new Date().toISOString(),
          semester: label,
          semesterStart: '',
          major: xsxx === undefined || xsxx.ZYMC === undefined ? '' : xsxx.ZYMC,
          courseCount: courses.length,
          courses: courses,
          loose: loose
        }
      };
    } finally {
      req.destroy();
    }
  }

  private static termLabel(xn: number, xq: number): string {
    const xqName: string = xq === 3 ? '1' : (xq === 12 ? '2' : '3');
    return `${xn}-${xn + 1} 学年第 ${xqName} 学期`;
  }

  private static async post(cookie: string, url: string, body: string): Promise<string> {
    const req: http.HttpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await req.request(url, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8',
          'X-Requested-With': 'XMLHttpRequest',
          'Referer': 'https://jw.swu.edu.cn/jwglxt/xtgl/index_initMenu.html',
          'Cookie': cookie
        },
        extraData: body,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: 20000
      });
      if (resp.responseCode === 901) {
        throw new Error('EXPIRED');
      }
      if (resp.responseCode !== 200) {
        return '';
      }
      return resp.result as string;
    } finally {
      req.destroy();
    }
  }

  /** 某学期的成绩 */
  static async fetchGrades(cookie: string, xn: number, xq: number): Promise<GradeItem[]> {
    const body: string =
      `xnm=${xn}&xqm=${xq}&_search=false&nd=${Date.now()}&queryModel.showCount=200&queryModel.currentPage=1&queryModel.sortName=&queryModel.sortOrder=asc&time=1`;
    const text: string = await JwSync.post(cookie, 'https://jw.swu.edu.cn/jwglxt/cjcx/cjcx_cxDgXscj.html?doType=query&gnmkdm=N305005', body);
    if (text === '') {
      return [];
    }
    if (text.charAt(0) !== '{') {
      throw new Error('成绩接口返回非 JSON');
    }
    const parsed: ApiGradeResp = JSON.parse(text) as ApiGradeResp;
    const items: ApiGradeItem[] = parsed.items === undefined || parsed.items === null ? [] : parsed.items;
    const out: GradeItem[] = [];
    for (let i: number = 0; i < items.length; i++) {
      const it: ApiGradeItem = items[i];
      out.push({
        term: JwSync.termLabel(xn, xq),
        name: String(it.kcmc === undefined ? '' : it.kcmc),
        score: String(it.cj === undefined || it.cj === null ? '' : it.cj),
        gpa: String(it.jd === undefined || it.jd === null ? '' : it.jd),
        credit: String(it.xf === undefined || it.xf === null ? '' : it.xf),
        nature: String(it.kcxzmc === undefined ? '' : it.kcxzmc),
        teacher: String(it.jsxm === undefined ? '' : it.jsxm),
        examType: String(it.ksxz === undefined ? '' : it.ksxz)
      });
    }
    return out;
  }

  /** 某学期的考试安排 */
  static async fetchExams(cookie: string, xn: number, xq: number): Promise<ExamItem[]> {
    const body: string =
      `xnm=${xn}&xqm=${xq}&ksmcdmb_id=&kch=&kc=&ksrq=&kkbm_id=&_search=false&nd=${Date.now()}&queryModel.showCount=200&queryModel.currentPage=1&queryModel.sortName=+&queryModel.sortOrder=asc&time=0`;
    const text: string = await JwSync.post(cookie, 'https://jw.swu.edu.cn/jwglxt/kwgl/kscx_cxXsksxxIndex.html?doType=query&gnmkdm=N358105', body);
    if (text === '') {
      return [];
    }
    if (text.charAt(0) !== '{') {
      throw new Error('考试接口返回非 JSON');
    }
    const parsed: ApiExamResp = JSON.parse(text) as ApiExamResp;
    const items: ApiExamItem[] = parsed.items === undefined || parsed.items === null ? [] : parsed.items;
    const out: ExamItem[] = [];
    for (let i: number = 0; i < items.length; i++) {
      const it: ApiExamItem = items[i];
      const campus: string = String(it.cdxqmc === undefined || it.cdxqmc === null ? '' : it.cdxqmc).trim();
      const room: string = String(it.cdmc === undefined || it.cdmc === null ? '' : it.cdmc).trim();
      out.push({
        term: JwSync.termLabel(xn, xq),
        name: String(it.kcmc === undefined ? '' : it.kcmc),
        time: String(it.kssj === undefined ? '' : it.kssj),
        place: room === '' ? campus : (campus === '' ? room : `${campus} ${room}`),
        teacher: String(it.jsxx === undefined ? '' : it.jsxx).split('/').pop() ?? '',
        examName: String(it.ksmc === undefined ? '' : it.ksmc)
      });
    }
    return out;
  }

  /** 拉最近两个学年、共 4 个学期 */
  static async fetchAll(cookie: string): Promise<SyncedSemesterData[]> {
    const out: SyncedSemesterData[] = [];
    const year: number = new Date().getFullYear();
    const combos: number[][] = [[year, 3], [year, 12], [year - 1, 3], [year - 1, 12]];
    for (let i: number = 0; i < combos.length; i++) {
      try {
        const one: SyncedSemesterData | null = await JwSync.fetchSemester(cookie, combos[i][0], combos[i][1]);
        if (one !== null) {
          out.push(one);
        }
      } catch (err) {
        throw err as Error;
      }
    }
    return out;
  }
}
