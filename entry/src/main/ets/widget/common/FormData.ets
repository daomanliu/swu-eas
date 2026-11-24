/**
 * 服务卡片数据：从首选项算好"当前/下一节课"和"下一场考试"
 * 只在卡片进程里跑，不 import JwSync，避免把 NetworkKit / ArkWeb 带进卡片进程
 */

import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import {
  Course,
  NowItem,
  TimetableSnapshot,
  MAX_WEEK,
  PERIODS,
  computeWeek,
  findNow,
  guessSemesterStart,
  humanDuration,
  minutesOf,
  weekdayLabel
} from '../../model/TimetableData';

/** 与 TimetableRepo 同一份首选项 */
const STORE_NAME: string = 'timetable_store';
const KEY_INDEX: string = 'semesters_index';
const KEY_EXAMS: string = 'exams_json';
const KEY_LEGACY: string = 'timetable_json';
const RAWFILE_LEGACY: string = 'timetable.json';
const DAY_MS: number = 86400000;

/** 与 TimetableRepo.SemesterRef 一致 */
interface SemesterRef {
  key: string;
  label: string;
  start: string;
  courseCount: number;
}

/** 与 TimetableRepo.SemesterIndex 一致 */
interface SemesterIndex {
  default: string;
  items: SemesterRef[];
}

/** 与 JwSync.ExamItem 一致（exams_json 里存的就是它的数组） */
interface ExamRecord {
  term: string;
  name: string;
  time: string;
  place: string;
  teacher: string;
  examName: string;
}

/** 某个学期 key 对应的快照 */
interface SnapshotHit {
  key: string;
  snapshot: TimetableSnapshot | null;
}

/** 一场考试解析出来的时间信息 */
interface ExamSchedule {
  ok: boolean;
  day: Date;
  startMin: number;
  endMin: number;
  dateLabel: string;
  slotLabel: string;
}

/**
 * 卡片上要显示的全部字段；统一用字符串，卡片侧用 @LocalStorageProp 原样接收
 * hasCourse / hasExam 取值为 '1' / '0'
 */
export interface CardData {
  statusLabel: string;
  hasCourse: string;
  courseName: string;
  coursePlace: string;
  courseWhen: string;
  courseTime: string;
  courseRemain: string;
  hasExam: string;
  examName: string;
  examDate: string;
  examSlot: string;
  examPlace: string;
  examRemain: string;
}

export class FormData {
  /** 卡片初始占位数据（onAddForm 同步返回，随后再异步推真实数据） */
  static empty(): CardData {
    return {
      statusLabel: '下一节课',
      hasCourse: '0',
      courseName: '',
      coursePlace: '',
      courseWhen: '',
      courseTime: '',
      courseRemain: '',
      hasExam: '0',
      examName: '',
      examDate: '',
      examSlot: '',
      examPlace: '',
      examRemain: ''
    };
  }

  static emptyJson(): string {
    return JSON.stringify(FormData.empty());
  }

  /** 读首选项算卡片数据，返回可直接给 formBindingData 的 JSON 字符串 */
  static async build(ctx: common.Context): Promise<string> {
    const now: Date = new Date();
    const data: CardData = FormData.empty();
    const store: preferences.Preferences | null = await FormData.openStore(ctx);

    const index: SemesterIndex | null = FormData.parseIndex(await FormData.readPref(store, KEY_INDEX));
    const hit: SnapshotHit = await FormData.loadBestSnapshot(ctx, store, index, now);
    if (hit.snapshot !== null) {
      FormData.fillCourse(data, hit.snapshot, hit.key, now);
    }

    const exams: ExamRecord[] = FormData.parseExams(await FormData.readPref(store, KEY_EXAMS));
    FormData.fillExam(data, exams, now);

    return JSON.stringify(data);
  }

  // ---------------------------------------------------------------- 课表

  /** 优先按"今天属于哪个学期"取，其次学期索引的默认值，最后任意有课的学期 */
  private static async loadBestSnapshot(
    ctx: common.Context,
    store: preferences.Preferences | null,
    index: SemesterIndex | null,
    now: Date
  ): Promise<SnapshotHit> {
    const keys: string[] = FormData.candidateKeys(index, now);
    let first: SnapshotHit | null = null;
    for (let i: number = 0; i < keys.length; i++) {
      const snap: TimetableSnapshot | null = await FormData.loadSnapshot(ctx, store, keys[i]);
      if (snap === null) {
        continue;
      }
      if (first === null) {
        first = { key: keys[i], snapshot: snap };
      }
      if (snap.courses.length > 0) {
        return { key: keys[i], snapshot: snap };
      }
    }
    if (first !== null) {
      return first;
    }
    // 老版本只有单份 timetable_json / timetable.json
    const legacy: TimetableSnapshot | null =
      FormData.parseSnapshot(await FormData.readPref(store, KEY_LEGACY));
    if (legacy !== null) {
      return { key: '', snapshot: legacy };
    }
    return { key: '', snapshot: FormData.parseSnapshot(FormData.readRaw(ctx, RAWFILE_LEGACY)) };
  }

  private static candidateKeys(index: SemesterIndex | null, now: Date): string[] {
    const keys: string[] = [];
    keys.push(FormData.currentSemesterKey(now));
    if (index !== null) {
      if (index.default !== '' && keys.indexOf(index.default) < 0) {
        keys.push(index.default);
      }
      for (let i: number = 0; i < index.items.length; i++) {
        const k: string = index.items[i].key;
        if (k !== '' && keys.indexOf(k) < 0) {
          keys.push(k);
        }
      }
    }
    return keys;
  }

  /** 按日期算"当下"是哪个学年学期，如 2026_3（与 Index.ets 的取法一致） */
  private static currentSemesterKey(now: Date): string {
    const m: number = now.getMonth() + 1;
    const y: number = now.getFullYear();
    const xn: number = (m >= 9) ? y : y - 1;
    const xq: number = (m >= 9 || m <= 1) ? 3 : 12;
    return `${xn}_${xq}`;
  }

  /** 先看 App 内同步的缓存，再看打包进 HAP 的 rawfile */
  private static async loadSnapshot(
    ctx: common.Context,
    store: preferences.Preferences | null,
    key: string
  ): Promise<TimetableSnapshot | null> {
    if (key === '') {
      return null;
    }
    const cached: TimetableSnapshot | null =
      FormData.parseSnapshot(await FormData.readPref(store, `tt_${key}`));
    if (cached !== null) {
      return cached;
    }
    return FormData.parseSnapshot(FormData.readRaw(ctx, `timetable_${key}.json`));
  }

  /** 复用 TimetableData 的 findNow / computeWeek / humanDuration 等工具函数 */
  private static fillCourse(data: CardData, snap: TimetableSnapshot, key: string, now: Date): void {
    if (snap.courses === undefined || snap.courses === null || snap.courses.length === 0) {
      return;
    }
    const start: string = snap.semesterStart !== '' ? snap.semesterStart : guessSemesterStart(key);
    if (start === '') {
      return;
    }
    let week: number = computeWeek(start, now);
    if (week < 1) {
      week = 1;
    }
    if (week > MAX_WEEK) {
      week = MAX_WEEK;
    }
    const item: NowItem = findNow(snap.courses, week, now);
    const c: Course | null = item.course;
    if (c === null || item.kind === 'none') {
      return;
    }

    data.hasCourse = '1';
    data.statusLabel = item.kind === 'now' ? '正在上课' : '下一节课';
    data.courseName = c.name;
    data.coursePlace = c.location === '' ? '地点待定' : c.location;
    // 上课时间直接取 PERIODS 里的 HH:mm，不再自己解析
    data.courseTime = PERIODS[c.start - 1].start;
    // 卡片由系统按 updateDuration 刷新（最小 30 分钟），"还有 X 分钟"会很快过期，
    // 这里只给与分钟无关的提示，精确剩余时间在应用内展示
    data.courseRemain = item.kind === 'now' ? '正在上课' : '即将开始';
    if (item.kind === 'now' || item.dayOffset === 0) {
      data.courseWhen = '今天';
    } else if (item.dayOffset === 1) {
      data.courseWhen = '明天';
    } else {
      data.courseWhen = weekdayLabel(c.weekday);
    }
  }

  // ---------------------------------------------------------------- 考试

  /** 取第一场还没考完的考试；time 形如 "2027-01-06(19:00-21:00)" */
  private static fillExam(data: CardData, exams: ExamRecord[], now: Date): void {
    if (exams.length === 0) {
      return;
    }
    const today: Date = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    const nowMin: number = now.getHours() * 60 + now.getMinutes();

    let pick: ExamRecord | null = null;
    let pickDayMs: number = 0;
    let pickStart: number = 0;
    let undated: ExamRecord | null = null;

    for (let i: number = 0; i < exams.length; i++) {
      const e: ExamRecord = exams[i];
      const s: ExamSchedule = FormData.parseExamSchedule(e.time);
      if (!s.ok) {
        if (undated === null) {
          undated = e;
        }
        continue;
      }
      const dayMs: number = s.day.getTime();
      if (dayMs < today.getTime()) {
        continue;
      }
      // 今天的场次如果已经结束就跳过
      if (dayMs === today.getTime() && s.endMin > 0 && nowMin > s.endMin) {
        continue;
      }
      if (pick === null || dayMs < pickDayMs || (dayMs === pickDayMs && s.startMin < pickStart)) {
        pick = e;
        pickDayMs = dayMs;
        pickStart = s.startMin;
      }
    }

    const chosen: ExamRecord | null = pick !== null ? pick : undated;
    if (chosen === null) {
      return;
    }
    const sch: ExamSchedule = FormData.parseExamSchedule(chosen.time);

    data.hasExam = '1';
    data.examName = chosen.name;
    data.examPlace = chosen.place === '' ? '考场待定' : chosen.place;
    data.examDate = sch.ok ? sch.dateLabel : '日期待定';
    data.examSlot = sch.ok ? sch.slotLabel : '';
    if (!sch.ok) {
      data.examRemain = '';
      return;
    }
    const days: number = Math.round((sch.day.getTime() - today.getTime()) / DAY_MS);
    data.examRemain = days <= 0 ? '就在今天' : `${days} 天后`;
  }

  /** "2027-01-06(19:00-21:00)" -> 日期 + 时段（HH:mm 用 TimetableData.minutesOf 换算） */
  private static parseExamSchedule(time: string): ExamSchedule {
    const none: ExamSchedule = {
      ok: false,
      day: new Date(0),
      startMin: 0,
      endMin: 0,
      dateLabel: '',
      slotLabel: ''
    };
    if (time === '') {
      return none;
    }
    const dm: RegExpMatchArray | null = time.match(/^(\d{4})-(\d{2})-(\d{2})/);
    if (dm === null) {
      return none;
    }
    const day: Date = new Date(Number(dm[1]), Number(dm[2]) - 1, Number(dm[3]));
    let startMin: number = 0;
    let endMin: number = 0;
    let slotLabel: string = '';
    const sm: RegExpMatchArray | null = time.match(/\(([^)]*)\)/);
    if (sm !== null) {
      slotLabel = sm[1].trim();
      const parts: string[] = slotLabel.split('-');
      if (parts.length >= 2) {
        startMin = minutesOf(parts[0]);
        endMin = minutesOf(parts[1]);
      }
    }
    return {
      ok: true,
      day: day,
      startMin: startMin,
      endMin: endMin,
      dateLabel: `${Number(dm[2])}/${Number(dm[3])}`,
      slotLabel: slotLabel
    };
  }

  // ---------------------------------------------------------------- 读写

  private static parseIndex(text: string): SemesterIndex | null {
    if (text === '') {
      return null;
    }
    try {
      const idx: SemesterIndex = JSON.parse(text) as SemesterIndex;
      if (idx === null || idx.items === undefined || idx.items === null || idx.items.length === 0) {
        return null;
      }
      return idx;
    } catch (err) {
      return null;
    }
  }

  private static parseSnapshot(text: string): TimetableSnapshot | null {
    if (text === '') {
      return null;
    }
    try {
      const snap: TimetableSnapshot = JSON.parse(text) as TimetableSnapshot;
      if (snap === null || snap.courses === undefined || snap.courses === null) {
        return null;
      }
      return snap;
    } catch (err) {
      return null;
    }
  }

  private static parseExams(text: string): ExamRecord[] {
    if (text === '') {
      return [];
    }
    try {
      const list: ExamRecord[] = JSON.parse(text) as ExamRecord[];
      if (list === null || list === undefined) {
        return [];
      }
      return list;
    } catch (err) {
      return [];
    }
  }

  private static async openStore(ctx: common.Context): Promise<preferences.Preferences | null> {
    try {
      return await preferences.getPreferences(ctx, STORE_NAME);
    } catch (err) {
      return null;
    }
  }

  private static async readPref(store: preferences.Preferences | null, key: string): Promise<string> {
    if (store === null) {
      return '';
    }
    try {
      return store.getSync(key, '') as string;
    } catch (err) {
      return '';
    }
  }

  private static readRaw(ctx: common.Context, name: string): string {
    try {
      const bytes: Uint8Array = ctx.resourceManager.getRawFileContentSync(name);
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(bytes);
    } catch (err) {
      return '';
    }
  }
}
