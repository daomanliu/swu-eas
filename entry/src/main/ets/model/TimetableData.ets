/**
 * 课程表数据类型与纯函数（不含 IO）
 * 运行时数据来自 resources/rawfile/timetable.json，由 tools/sync-timetable.mjs 生成
 */

export interface Period {
  index: number;
  start: string;
  end: string;
  group: string;
}

export interface Weekday {
  index: number;
  label: string;
}

export interface Course {
  id: string;
  name: string;
  teacher: string;
  location: string;
  weekday: number;   // 1=周一 ... 7=周日
  start: number;     // 起始节次
  end: number;       // 结束节次
  weeks: number[];
  practice: boolean;
  note: string;
  credit: string;
}

export interface LooseCourse {
  id: string;
  name: string;
  teacher: string;
  weeks: string;
  note: string;
}

/** rawfile 里的完整快照 */
export interface TimetableSnapshot {
  generatedAt: string;
  semester: string;
  semesterStart: string;
  major: string;
  courseCount: number;
  courses: Course[];
  loose: LooseCourse[];
}

/** “当前/下一节”查询结果 */
export interface NowItem {
  kind: string;        // now | next | none
  course: Course | null;
  minutes: number;     // now: 距下课；next: 距上课
  dayOffset: number;   // 0=今天 1=明天 …
}

export const PERIODS: Period[] = [
  { index: 1, start: '08:00', end: '08:45', group: '上午' },
  { index: 2, start: '08:55', end: '09:40', group: '上午' },
  { index: 3, start: '10:00', end: '10:45', group: '上午' },
  { index: 4, start: '10:55', end: '11:40', group: '上午' },
  { index: 5, start: '12:10', end: '12:55', group: '中午' },
  { index: 6, start: '13:05', end: '13:50', group: '中午' },
  { index: 7, start: '14:00', end: '14:45', group: '下午' },
  { index: 8, start: '14:55', end: '15:40', group: '下午' },
  { index: 9, start: '15:50', end: '16:35', group: '下午' },
  { index: 10, start: '16:55', end: '17:40', group: '下午' },
  { index: 11, start: '17:50', end: '18:35', group: '下午' },
  // 晚上三节：最后一节 21:55 下课（与教务课表页一致）
  { index: 12, start: '19:20', end: '20:05', group: '晚上' },
  { index: 13, start: '20:15', end: '21:00', group: '晚上' },
  { index: 14, start: '21:10', end: '21:55', group: '晚上' }
];

export const WEEKDAYS: Weekday[] = [
  { index: 1, label: '一' },
  { index: 2, label: '二' },
  { index: 3, label: '三' },
  { index: 4, label: '四' },
  { index: 5, label: '五' },
  { index: 6, label: '六' },
  { index: 7, label: '日' }
];

export const MAX_WEEK: number = 24;
const DAY_MS: number = 86400000;

export function isActive(course: Course, week: number): boolean {
  return course.weeks.indexOf(week) >= 0;
}

/** 周次压缩显示：1-3,5,6,8-16 周 */
export function weeksLabel(weeks: number[]): string {
  const sorted: number[] = weeks.slice().sort((a: number, b: number) => a - b);
  const parts: string[] = [];
  let i: number = 0;
  while (i < sorted.length) {
    let j: number = i;
    while (j + 1 < sorted.length && sorted[j + 1] === sorted[j] + 1) {
      j++;
    }
    parts.push(i === j ? `${sorted[i]}` : `${sorted[i]}-${sorted[j]}`);
    i = j + 1;
  }
  return parts.join(',') + ' 周';
}

/** "08:00 - 09:40" */
export function timeRange(start: number, end: number): string {
  if (start < 1 || end > PERIODS.length || start > end) {
    return '';
  }
  return `${PERIODS[start - 1].start} - ${PERIODS[end - 1].end}`;
}

export function weekdayLabel(day: number): string {
  const w: Weekday | undefined = WEEKDAYS.find((item: Weekday) => item.index === day);
  return w === undefined ? '' : `周${w.label}`;
}

/** "08:00" -> 480 */
export function minutesOf(hhmm: string): number {
  const parts: string[] = hhmm.split(':');
  if (parts.length < 2) {
    return 0;
  }
  return Number(parts[0]) * 60 + Number(parts[1]);
}

/** 分钟数 -> "25 分钟" / "1 小时 20 分" */
export function humanDuration(minutes: number): string {
  const m: number = Math.max(0, Math.round(minutes));
  if (m < 60) {
    return `${m} 分钟`;
  }
  const h: number = Math.floor(m / 60);
  const rest: number = m % 60;
  return rest === 0 ? `${h} 小时` : `${h} 小时 ${rest} 分`;
}

/** 今天的星期序号（周一=1 … 周日=7） */
export function todayIndex(now: Date): number {
  const d: number = now.getDay();
  return d === 0 ? 7 : d;
}

/** 从学期起始日推算第几周（不小于 1） */
export function computeWeek(semesterStart: string, now: Date): number {
  const parts: string[] = semesterStart.split('-');
  if (parts.length < 3) {
    return 1;
  }
  const startMonday = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]));
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const shift: number = (todayIndex(today) - 1) * DAY_MS;
  const thisMonday = new Date(today.getTime() - shift);
  const diff: number = Math.round((thisMonday.getTime() - startMonday.getTime()) / (7 * DAY_MS));
  return diff + 1;
}

/** 找“正在上课”或“下一节课”；都找不到返回 none */
export function findNow(courses: Course[], week: number, now: Date): NowItem {
  const today: number = todayIndex(now);
  const nowMin: number = now.getHours() * 60 + now.getMinutes();

  for (let offset: number = 0; offset < 7; offset++) {
    const day: number = ((today - 1 + offset) % 7) + 1;
    const list: Course[] = courses
      .filter((c: Course) => c.weekday === day && isActive(c, week))
      .sort((a: Course, b: Course) => a.start - b.start);

    if (offset === 0) {
      for (let i: number = 0; i < list.length; i++) {
        const c: Course = list[i];
        const s: number = minutesOf(PERIODS[c.start - 1].start);
        const e: number = minutesOf(PERIODS[c.end - 1].end);
        if (nowMin >= s && nowMin < e) {
          return { kind: 'now', course: c, minutes: e - nowMin, dayOffset: 0 };
        }
      }
    }

    for (let i: number = 0; i < list.length; i++) {
      const c: Course = list[i];
      const s: number = minutesOf(PERIODS[c.start - 1].start);
      if (offset > 0 || s > nowMin) {
        const wait: number = offset > 0 ? s - nowMin + offset * 1440 : s - nowMin;
        return { kind: 'next', course: c, minutes: wait, dayOffset: offset };
      }
    }
  }

  return { kind: 'none', course: null, minutes: 0, dayOffset: -1 };
}

/**
 * App 内同步拿不到学期起始日时的推算：
 * 第 1 学期 ≈ 9 月 1 日所在周的周一；第 2 学期 ≈ 次年 3 月 1 日所在周的周一
 */
export function guessSemesterStart(key: string): string {
  const parts: string[] = key.split('_');
  if (parts.length < 2) {
    return '';
  }
  const xn: number = Number(parts[0]);
  const xq: number = Number(parts[1]);
  if (isNaN(xn) || isNaN(xq)) {
    return '';
  }
  const anchor: Date = xq === 3 ? new Date(xn, 8, 1) : new Date(xn + 1, 2, 1);
  const dow: number = anchor.getDay() === 0 ? 7 : anchor.getDay();
  const monday = new Date(anchor.getTime() - (dow - 1) * DAY_MS);
  const mm: string = `0${monday.getMonth() + 1}`.slice(-2);
  const dd: string = `0${monday.getDate()}`.slice(-2);
  return `${monday.getFullYear()}-${mm}-${dd}`;
}

/** ISO 时间 -> "11-22 13:30" */
export function formatSyncTime(iso: string): string {
  if (!iso) {
    return '';
  }
  const d: Date = new Date(iso);
  if (isNaN(d.getTime())) {
    return '';
  }
  const mm: string = `0${d.getMonth() + 1}`.slice(-2);
  const dd: string = `0${d.getDate()}`.slice(-2);
  const hh: string = `0${d.getHours()}`.slice(-2);
  const mi: string = `0${d.getMinutes()}`.slice(-2);
  return `${mm}-${dd} ${hh}:${mi}`;
}
