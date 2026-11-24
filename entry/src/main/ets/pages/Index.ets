import { common } from '@kit.AbilityKit';
import {
  Course,
  LooseCourse,
  Period,
  Weekday,
  NowItem,
  MAX_WEEK,
  PERIODS,
  WEEKDAYS,
  isActive,
  weeksLabel,
  timeRange,
  weekdayLabel,
  humanDuration,
  computeWeek,
  findNow,
  formatSyncTime,
  guessSemesterStart,
  todayIndex
} from '../model/TimetableData';
import { router, uiMaterial } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { HdsTabs, HdsTabsController, hdsMaterial, hdsEffect } from '@kit.UIDesignKit';
import { SyncPage } from './SyncPage';
import { TimetableRepo, LoadResult, SemesterRef } from '../model/TimetableRepo';
import { GradeItem, ExamItem } from '../model/JwSync';

interface Slot {
  period: number;
  span: number;
  course: Course | null;
}

/** 成绩列表的一行：学期标题或一条成绩 */
interface GradeRow {
  kind: string;    // term | item
  term: string;
  summary: string;
  name: string;
  score: string;
  gpa: string;
  credit: string;
  nature: string;
  teacher: string;
  examType: string;
}

const EMPTY_NOW: NowItem = { kind: 'none', course: null, minutes: 0, dayOffset: -1 };
const DAY_MS: number = 86400000;

@Entry
@Component
struct Index {
  @State week: number = 1;
  @State semester: string = '';
  @State semesterStart: string = '2026-08-31';
  @State courses: Course[] = [];
  @State loose: LooseCourse[] = [];
  @State selected: Course | null = null;
  @State sheetShow: boolean = false;
  @State loading: boolean = true;
  @State sourceLabel: string = '';
  @State lastSyncAt: string = '';
  @State tab: number = 0;
  @State grades: GradeItem[] = [];
  @State exams: ExamItem[] = [];
  @State gradeTerm: string = '';
  @State examTerm: string = '';
  @State showGradeTerm: boolean = false;
  @State showExamTerm: boolean = false;
  @State materialOk: boolean = false;
  @State selGrade: GradeRow | null = null;
  @State showGradeDetail: boolean = false;
  @State showLogin: boolean = false;
  @State railOpen: boolean = false;
  @State showAddHint: boolean = false;
  @StorageProp('backTick') @Watch('onBackTick') backTick: number = 0;
  @StorageProp('topInset') topInset: number = 0;
  @StorageProp('bottomInset') bottomInset: number = 0;
  @State selExam: ExamItem | null = null;
  @State showExamDetail: boolean = false;

  private material: uiMaterial.ImmersiveMaterial | undefined = undefined;
  private hdsController: HdsTabsController = new HdsTabsController();
  /** 物理光效：点光源照亮卡片边缘 */
  private cardLight: VisualEffect = new hdsEffect.HdsEffectBuilder().buildEffect();
  @State updatedAt: string = '';
  @State semesters: SemesterRef[] = [];
  @State semesterKey: string = '';
  @State showSemester: boolean = false;
  @State nowItem: NowItem = EMPTY_NOW;
  @State tick: number = 0;
  @State zoom: number = 1;

  private timerId: number = -1;
  private inited: boolean = false;
  private baseZoom: number = 1;
  private rowH: number = 54;
  private colW: number = 98;
  private timeW: number = 34;
  private headH: number = 36;
  private static readonly BASE_COL: number = 98;
  private static readonly BASE_ROW: number = 54;
  private static readonly MIN_ZOOM: number = 0.7;
  private static readonly MAX_ZOOM: number = 1.7;
  private static readonly BASE_TIME_W: number = 34;
  private static readonly BASE_HEAD_H: number = 36;
  private static readonly BASE_NAME_FONT: number = 10;
  private static readonly BASE_LOC_FONT: number = 8;

  /** 缩放只改列宽/行高/字号，文字保持矢量清晰 */
  private applyZoom(z: number): void {
    const clamped: number = Math.min(Index.MAX_ZOOM, Math.max(Index.MIN_ZOOM, z));
    this.zoom = clamped;
    this.colW = Index.BASE_COL * clamped;
    this.rowH = Index.BASE_ROW * clamped;
    this.timeW = Index.BASE_TIME_W * clamped;
    this.headH = Index.BASE_HEAD_H * clamped;
  }

  private nameFont(): number {
    return Index.BASE_NAME_FONT * Math.min(this.zoom, 1.25);
  }

  private locFont(): number {
    return Index.BASE_LOC_FONT * Math.min(this.zoom, 1.25);
  }

  aboutToAppear(): void {
    try {
      if (uiMaterial.isImmersiveMaterialSupported()) {
        this.material = new uiMaterial.ImmersiveMaterial();
        this.materialOk = true;
      }
    } catch (err) {
      this.materialOk = false;
    }
    try {
      this.cardLight = new hdsEffect.HdsEffectBuilder()
        .pointLight({
          sourceType: hdsEffect.PointLightSourceType.SOFT,
          illuminatedType: hdsEffect.PointLightIlluminatedType.DEFAULT_FEATHERING_BORDER,
          options: {
            color: $r('app.color.brand_text'),
            intensity: 1,
            height: 12,
            bloom: 0.5
          }
        })
        .buildEffect();
    } catch (err) {
      // 设备不支持时保持空效果
    }
    this.applyZoom(this.zoom);
    this.init();
    this.timerId = setInterval(() => {
      this.tick = this.tick + 1;
      this.refreshNow();
    }, 60000);
  }

  aboutToDisappear(): void {
    if (this.timerId !== -1) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  private ctxOrNull(): common.UIAbilityContext | null {
    const ctx: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    return (ctx === undefined || ctx === null) ? null : ctx;
  }

  private async init(): Promise<void> {
    const ctx: common.UIAbilityContext | null = this.ctxOrNull();
    if (ctx === null) {
      this.loading = false;
      this.inited = true;
      return;
    }

    this.lastSyncAt = await TimetableRepo.lastSyncAt(ctx);
    const gradesJson: string = await TimetableRepo.loadGrades(ctx);
    const examsJson: string = await TimetableRepo.loadExams(ctx);
    if (gradesJson !== '') {
      try {
        this.grades = JSON.parse(gradesJson) as GradeItem[];
      } catch (err) {
        this.grades = [];
      }
    }
    if (examsJson !== '') {
      try {
        this.exams = JSON.parse(examsJson) as ExamItem[];
      } catch (err) {
        this.exams = [];
      }
    }
    this.resetDefaultTerms();

    const idx = await TimetableRepo.loadIndexCached(ctx);
    if (idx !== null) {
      this.semesters = idx.items;
      this.loading = false;
      await this.applySemester(idx.default);
      this.inited = true;
      return;
    }

    // 兼容老数据：单个 timetable.json
    const res: LoadResult = await TimetableRepo.load(ctx);
    this.loading = false;
    this.applySnapshot(res);
    this.inited = true;
  }

  onPageShow(): void {
    if (this.inited) {
      this.reload();
    }
  }

  private async clearAll(): Promise<void> {
    const ctx: common.UIAbilityContext | null = this.ctxOrNull();
    if (ctx === null) {
      return;
    }
    await TimetableRepo.clear(ctx);
    this.semesters = [];
    this.semesterKey = '';
    this.courses = [];
    this.loose = [];
    this.selected = null;
    this.showSemester = false;
    await this.init();
  }

  private async reload(): Promise<void> {
    const ctx: common.UIAbilityContext | null = this.ctxOrNull();
    if (ctx === null) {
      return;
    }
    this.lastSyncAt = await TimetableRepo.lastSyncAt(ctx);

    const gradesJson: string = await TimetableRepo.loadGrades(ctx);
    const examsJson: string = await TimetableRepo.loadExams(ctx);
    if (gradesJson !== '') {
      try {
        this.grades = JSON.parse(gradesJson) as GradeItem[];
      } catch (err) {
        this.grades = [];
      }
    }
    if (examsJson !== '') {
      try {
        this.exams = JSON.parse(examsJson) as ExamItem[];
      } catch (err) {
        this.exams = [];
      }
    }
    this.resetDefaultTerms();

    const idx = await TimetableRepo.loadIndexCached(ctx);
    if (idx !== null) {
      this.semesters = idx.items;
      if (this.semesterKey === '' || !idx.items.some((s: SemesterRef) => s.key === this.semesterKey)) {
        this.semesterKey = idx.default;
      }
    }
    await this.applySemester(this.semesterKey);
  }

  private applySnapshot(res: LoadResult): void {
    if (res.snapshot === null) {
      return;
    }
    this.semester = res.snapshot.semester;
    this.semesterStart = res.snapshot.semesterStart !== ''
      ? res.snapshot.semesterStart
      : guessSemesterStart(this.semesterKey);
    this.courses = res.snapshot.courses;
    this.loose = res.snapshot.loose;
    this.week = this.currentWeek();
    this.updatedAt = formatSyncTime(res.snapshot.generatedAt);
    this.sourceLabel = this.lastSyncAt !== '' ? '本地缓存' : '';
    this.selected = null;
    this.refreshNow();
  }

  private async applySemester(key: string): Promise<void> {
    const ctx: common.UIAbilityContext | null = this.ctxOrNull();
    if (ctx === null || key === '') {
      return;
    }
    const res: LoadResult = await TimetableRepo.loadSemester(ctx, key);
    if (res.snapshot === null) {
      return;
    }
    this.semesterKey = key;
    this.applySnapshot(res);
  }

  /** 按日期算"当下"是哪个学年学期，如 2026_3 */
  private currentSemesterKey(): string {
    const now = new Date();
    const m: number = now.getMonth() + 1;
    const y: number = now.getFullYear();
    const xn: number = (m >= 9) ? y : y - 1;
    const xq: number = (m >= 9 || m <= 1) ? 3 : 12;
    return `${xn}_${xq}`;
  }

  private keyOrder(key: string): number {
    const parts: string[] = key.split('_');
    const y: number = Number(parts[0]);
    const x: number = parts.length > 1 && parts[1] === '3' ? 1 : 2;
    return y * 10 + x;
  }

  private semesterTag(s: SemesterRef): string {
    const cur: string = this.currentSemesterKey();
    if (s.key === cur) {
      return '当前学期';
    }
    return this.keyOrder(s.key) > this.keyOrder(cur) ? '未开始' : '历史学期';
  }

  /** 当前学期算真实周次；历史学期（无起始日）从第 1 周开始 */
  private currentWeek(): number {
    if (this.semesterStart === '') {
      return 1;
    }
    const w: number = computeWeek(this.semesterStart, new Date());
    return (w < 1 || w > MAX_WEEK) ? 1 : w;
  }

  private refreshNow(): void {
    if (this.courses.length === 0) {
      return;
    }
    this.nowItem = findNow(this.courses, this.week, new Date());
  }

  private step(delta: number): void {
    const next: number = this.week + delta;
    if (next < 1 || next > MAX_WEEK) {
      return;
    }
    this.week = next;
    this.refreshNow();
  }

  /** 当前周对应的日期区间，如 "11/16 - 11/22" */
  private weekRange(): string {
    const p: string[] = this.semesterStart.split('-');
    if (p.length < 3) {
      return '';
    }
    const start = new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2]));
    const mon = new Date(start.getTime() + (this.week - 1) * 7 * DAY_MS);
    const sun = new Date(mon.getTime() + 6 * DAY_MS);
    const fmt = (dt: Date): string => `${dt.getMonth() + 1}/${dt.getDate()}`;
    return `${fmt(mon)} - ${fmt(sun)}`;
  }

  private layout(day: number): Slot[] {
    const slots: Slot[] = [];
    let p: number = 1;
    while (p <= PERIODS.length) {
      const hit: Course | undefined = this.courses.find((c: Course) =>
        c.weekday === day && c.start === p && isActive(c, this.week));
      if (hit !== undefined) {
        slots.push({ period: p, span: hit.end - hit.start + 1, course: hit });
        p = hit.end + 1;
      } else {
        slots.push({ period: p, span: 1, course: null });
        p += 1;
      }
    }
    return slots;
  }

  private today(): number {
    return todayIndex(new Date());
  }

  private nowTag(): string {
    if (this.nowItem.kind === 'now') {
      return '正在上课';
    }
    if (this.nowItem.kind === 'next') {
      return '下一节课';
    }
    return '本周';
  }

  private nowColor(): ResourceColor {
    if (this.nowItem.kind === 'now') {
      return $r('app.color.success');
    }
    if (this.nowItem.kind === 'next') {
      return $r('app.color.brand_text');
    }
    return $r('app.color.text_hint');
  }

  private nowTitle(): string {
    const c: Course | null = this.nowItem.course;
    return c === null ? '没有更多课了' : c.name;
  }

  private nowSub(): string {
    const c: Course | null = this.nowItem.course;
    if (c === null) {
      return '当前周次已无安排，休息一下';
    }
    return `${c.location} · ${c.teacher}`;
  }

  private nowRange(): string {
    const c: Course | null = this.nowItem.course;
    if (c === null) {
      return '';
    }
    return `${c.start}-${c.end} 节 · ${timeRange(c.start, c.end)}`;
  }

  private nowTail(): string {
    const c: Course | null = this.nowItem.course;
    if (c === null) {
      return '';
    }
    if (this.nowItem.kind === 'now') {
      return `距下课 ${humanDuration(this.nowItem.minutes)}`;
    }
    const prefix: string = this.nowItem.dayOffset === 0 ? '今天' : weekdayLabel(c.weekday);
    return `${prefix} ${PERIODS[c.start - 1].start} · 还有 ${humanDuration(this.nowItem.minutes)}`;
  }

  private selWeekHint(): string {
    const c: Course | null = this.selected;
    if (c === null) {
      return '';
    }
    return isActive(c, this.week)
      ? `本周（第 ${this.week} 周）有课`
      : `本周（第 ${this.week} 周）不上这门课`;
  }

  private resetDefaultTerms(): void {
    if (this.gradeTerm === '') {
      const gt: string[] = [];
      for (let i: number = 0; i < this.grades.length; i++) {
        if (gt.indexOf(this.grades[i].term) < 0) {
          gt.push(this.grades[i].term);
        }
      }
      this.gradeTerm = this.pickDefaultTerm(gt);
    }
    if (this.examTerm === '') {
      const et: string[] = [];
      for (let i: number = 0; i < this.exams.length; i++) {
        if (et.indexOf(this.exams[i].term) < 0) {
          et.push(this.exams[i].term);
        }
      }
      this.examTerm = this.pickDefaultTerm(et);
    }
  }

  /** 把成绩摊平成"学期标题 + 成绩"的行，顺便算该学期加权均分 */
  private gradeRows(): GradeRow[] {
    const rows: GradeRow[] = [];
    const source: GradeItem[] = this.gradesFiltered();
    const terms: string[] = [];
    for (let i: number = 0; i < source.length; i++) {
      const t: string = source[i].term;
      if (terms.indexOf(t) < 0) {
        terms.push(t);
      }
    }
    terms.sort((a: string, b: string) => b.localeCompare(a));

    for (let i: number = 0; i < terms.length; i++) {
      const term: string = terms[i];
      const items: GradeItem[] = source.filter((g: GradeItem) => g.term === term);
      let creditSum: number = 0;
      let weighted: number = 0;
      let gpaWeighted: number = 0;
      for (let j: number = 0; j < items.length; j++) {
        const c: number = Number(items[j].credit);
        const s: number = Number(items[j].score);
        const gp: number = Number(items[j].gpa);
        if (!isNaN(c) && c > 0) {
          creditSum += c;
          if (!isNaN(s)) {
            weighted += s * c;
          }
          if (!isNaN(gp)) {
            gpaWeighted += gp * c;
          }
        }
      }
      const avg: string = creditSum > 0 ? (weighted / creditSum).toFixed(1) : '—';
      const gpaAvg: string = creditSum > 0 ? (gpaWeighted / creditSum).toFixed(2) : '—';
      rows.push({
        kind: 'term',
        term: term,
        summary: `${items.length} 门 · 均分 ${avg} · 绩点 ${gpaAvg}`,
        name: '', score: '', gpa: '', credit: '', nature: '',
        teacher: '', examType: ''
      });
      for (let j: number = 0; j < items.length; j++) {
        const it: GradeItem = items[j];
        rows.push({
          kind: 'item', term: term, summary: '',
          name: it.name, score: it.score, gpa: it.gpa,
          credit: it.credit, nature: it.nature,
          teacher: it.teacher, examType: it.examType
        });
      }
    }
    return rows;
  }

  private gradeSummary(): string {
    const src: GradeItem[] = this.gradesFiltered();
    if (src.length === 0) {
      return '同步后显示';
    }
    let creditSum: number = 0;
    let weighted: number = 0;
    let gpaWeighted: number = 0;
    for (let i: number = 0; i < src.length; i++) {
      const c: number = Number(src[i].credit);
      const s: number = Number(src[i].score);
      const gp: number = Number(src[i].gpa);
      if (!isNaN(c) && c > 0) {
        creditSum += c;
        if (!isNaN(s)) {
          weighted += s * c;
        }
        if (!isNaN(gp)) {
          gpaWeighted += gp * c;
        }
      }
    }
    if (creditSum === 0) {
      return `${src.length} 门课`;
    }
    return `${src.length} 门课 · 加权均分 ${(weighted / creditSum).toFixed(1)} · 绩点 ${(gpaWeighted / creditSum).toFixed(2)}`;
  }

  private timetableSubtitle(): string {
    if (this.courses.length === 0) {
      return '同步后显示';
    }
    return this.sourceLabel === ''
      ? `共 ${this.courses.length} 门课`
      : `共 ${this.courses.length} 门课 · ${this.sourceLabel}`;
  }

  private examSummary(): string {
    const src: ExamItem[] = this.examsFiltered();
    if (src.length === 0) {
      return '同步后显示';
    }
    return `${src.length} 场 · ${src[0].time === '' ? '时间待定' : src[0].time.slice(0, 10)}`;
  }

  private scoreColor(score: string): ResourceColor {
    const s: number = Number(score);
    if (isNaN(s)) {
      return $r('app.color.text_primary');
    }
    if (s >= 90) {
      return $r('app.color.success');
    }
    if (s >= 60) {
      return $r('app.color.text_primary');
    }
    return $r('app.color.danger');
  }

  /** "2027-01-06(19:00-21:00)" -> "1/6" */
  private examDate(t: string): string {
    const m: RegExpMatchArray | null = t.match(/^(\d{4})-(\d{2})-(\d{2})/);
    if (m === null) {
      return t;
    }
    return `${Number(m[2])}/${Number(m[3])}`;
  }

  /** "2027-01-06(19:00-21:00)" -> "19:00-21:00" */
  private examTime(t: string): string {
    const m: RegExpMatchArray | null = t.match(/\((.*)\)/);
    return m === null ? '' : m[1];
  }

  @Builder
  termSheet(isGrade: boolean) {
    Column() {
      Text('选择学期')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_strong'))
        .margin({ bottom: 6 })

      List() {
        ForEach(isGrade ? this.gradeTerms() : this.examTerms(), (t: string) => {
          ListItem() {
            Row() {
              Text(t === '' ? '全部学期' : t)
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
                .layoutWeight(1)
              if (t === (isGrade ? this.gradeTerm : this.examTerm)) {
                Text('当前')
                  .fontSize(10)
                  .fontColor($r('app.color.on_brand'))
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                  .borderRadius(8)
                  .backgroundColor($r('app.color.brand_text'))

              }
            }
            .width('100%')
            .padding({ top: 12, bottom: 12 })
          }
          .onClick(() => {
            if (isGrade) {
              this.gradeTerm = t;
              this.showGradeTerm = false;
            } else {
              this.examTerm = t;
              this.showExamTerm = false;
            }
          })
        }, (t: string) => (isGrade ? 'g_' : 'e_') + t)
      }
      .height((isGrade ? this.gradeTerms().length : this.examTerms().length) * 48)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 4, bottom: 20 })
    .alignItems(HorizontalAlign.Start)
  }

  /** 当前学期的显示名，如 "2026-2027 学年第 1 学期" */
  private currentTermLabel(): string {
    const now = new Date();
    const m: number = now.getMonth() + 1;
    const y: number = now.getFullYear();
    const xn: number = (m >= 9) ? y : y - 1;
    const xq: number = (m >= 9 || m <= 1) ? 1 : 2;
    return `${xn}-${xn + 1} 学年第 ${xq} 学期`;
  }

  /** 优先本学期；本学期没数据时退回最新一个有数据的学期 */
  private pickDefaultTerm(terms: string[]): string {
    if (terms.length === 0) {
      return '';
    }
    const cur: string = this.currentTermLabel();
    if (terms.indexOf(cur) >= 0) {
      return cur;
    }
    const sorted: string[] = terms.slice().sort((a: string, b: string) => b.localeCompare(a));
    return sorted[0];
  }

  private gradeTerms(): string[] {
    const termSet: string[] = [];
    for (let i: number = 0; i < this.grades.length; i++) {
      const t: string = this.grades[i].term;
      if (termSet.indexOf(t) < 0) {
        termSet.push(t);
      }
    }
    termSet.sort((a: string, b: string) => b.localeCompare(a));
    termSet.unshift('');
    return termSet;
  }

  private examTerms(): string[] {
    const termSet: string[] = [];
    for (let i: number = 0; i < this.exams.length; i++) {
      const t: string = this.exams[i].term;
      if (termSet.indexOf(t) < 0) {
        termSet.push(t);
      }
    }
    termSet.sort((a: string, b: string) => b.localeCompare(a));
    termSet.unshift('');
    return termSet;
  }

  private gradesFiltered(): GradeItem[] {
    if (this.gradeTerm === '') {
      return this.grades;
    }
    return this.grades.filter((g: GradeItem) => g.term === this.gradeTerm);
  }

  private examsFiltered(): ExamItem[] {
    if (this.examTerm === '') {
      return this.exams;
    }
    return this.exams.filter((e: ExamItem) => e.term === this.examTerm);
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      HdsTabs({ barPosition: BarPosition.End, controller: this.hdsController }) {
        TabContent() {
          this.homePage()
        }
        .tabBar(this.tabIcon($r('sys.symbol.house'), $r('sys.symbol.house'), '首页', 0))

        TabContent() {
          this.timetablePage()
        }
        .tabBar(this.tabIcon($r('sys.symbol.calendar'), $r('sys.symbol.calendar'), '课表', 1))

        TabContent() {
          this.gradesPage()
        }
        .tabBar(this.tabIcon($r('sys.symbol.graduationcap'), $r('sys.symbol.graduationcap'), '成绩', 2))

        TabContent() {
          this.examsPage()
        }
        .tabBar(this.tabIcon($r('sys.symbol.doc_text'), $r('sys.symbol.doc_text'), '考试', 3))
      }
      .barOverlap(true)
      .barPosition(BarPosition.End)
      .barBackgroundColor(Color.Transparent)
      .barBackgroundBlurStyle(BlurStyle.NONE)
      .barFloatingStyle({
        barSideMargin: 16,
        barBottomMargin: this.bottomInset + 6,
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      })
      .onChange((index: number) => {
        this.tab = index;
      })
      .width('100%')
      .height('100%')

      this.sideRail()

      if (this.showLogin) {
        this.loginCover()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .bindSheet(this.sheetShow, this.detailSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: false,
      backgroundColor: $r('app.color.sheet_bg'),
        blurStyle: BlurStyle.COMPONENT_THICK,
      onDisappear: () => {
        this.sheetShow = false;
        this.selected = null;
      }
    })
  }

  // ================= 首页 =================

  private examStartMs(t: string): number {
    const m: RegExpMatchArray | null = t.match(/^(\d{4})-(\d{2})-(\d{2})\((\d{2}):(\d{2})/);
    if (m === null) {
      return Number.MAX_SAFE_INTEGER;
    }
    return new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]), Number(m[4]), Number(m[5])).getTime();
  }

  private nextExam(): ExamItem | null {
    const now: number = Date.now();
    let best: ExamItem | null = null;
    let bestMs: number = Number.MAX_SAFE_INTEGER;
    for (let i: number = 0; i < this.exams.length; i++) {
      const ms: number = this.examStartMs(this.exams[i].time);
      if (ms > now && ms < bestMs) {
        best = this.exams[i];
        bestMs = ms;
      }
    }
    return best;
  }

  /** 必修 + 专业选修；排除国际课程与跨专业选修 */
  private coreGrades(): GradeItem[] {
    const out: GradeItem[] = [];
    for (let i: number = 0; i < this.grades.length; i++) {
      const n: string = this.grades[i].nature;
      if (n.indexOf('国际') >= 0 || n.indexOf('跨专业') >= 0) {
        continue;
      }
      if (n.indexOf('必修') >= 0 || n.indexOf('专业选修') >= 0) {
        out.push(this.grades[i]);
      }
    }
    return out;
  }

  private coreAvg(): number {
    const list: GradeItem[] = this.coreGrades();
    let cw: number = 0;
    let sum: number = 0;
    for (let i: number = 0; i < list.length; i++) {
      const c: number = Number(list[i].credit);
      const s: number = Number(list[i].score);
      if (!isNaN(c) && !isNaN(s) && c > 0) {
        cw += c;
        sum += c * s;
      }
    }
    return cw === 0 ? 0 : sum / cw;
  }

  private coreGpa(): number {
    const list: GradeItem[] = this.coreGrades();
    let cw: number = 0;
    let sum: number = 0;
    for (let i: number = 0; i < list.length; i++) {
      const c: number = Number(list[i].credit);
      const gp: number = Number(list[i].gpa);
      if (!isNaN(c) && !isNaN(gp) && c > 0) {
        cw += c;
        sum += c * gp;
      }
    }
    return cw === 0 ? 0 : sum / cw;
  }

  private coreCredit(): number {
    const list: GradeItem[] = this.coreGrades();
    let c: number = 0;
    for (let i: number = 0; i < list.length; i++) {
      const v: number = Number(list[i].credit);
      if (!isNaN(v)) {
        c += v;
      }
    }
    return c;
  }

  @Builder
  homePage() {
    Column() {
      Row() {
        Column() {
          Text('首页')
            .fontSize(19)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.on_brand'))
          Text(this.lastSyncAt === '' ? '同步后显示' : this.syncLabel())
            .fontSize(11)
            .fontColor($r('app.color.on_brand_sub'))
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Row() {
          Text(this.semester === '' ? '未同步' : this.semester)
            .fontSize(10)
            .fontColor($r('app.color.on_brand_chip_text'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          SymbolGlyph($r('sys.symbol.chevron_down'))
            .fontSize(9)
            .fontColor([$r('app.color.on_brand_chip_text')])
            .margin({ left: 3 })
        }
        .constraintSize({ maxWidth: 150 })
        .padding({ left: 10, right: 8, top: 6, bottom: 6 })
        .borderRadius(13)
        .backgroundColor($r('app.color.on_brand_chip'))
        .onClick(() => {
          this.showSemester = true;
        })
      }
      .width('100%')
      .padding({ left: 16, right: 14, top: this.topInset + 14, bottom: 12 })
      .backgroundColor($r('app.color.header_material_bg'))

      if (this.courses.length === 0 && this.grades.length === 0) {
        this.pageEmpty($r('sys.symbol.house'), '还没有数据', '登录一次教务系统，课表成绩考试一起抓')
      } else {
        Scroll() {
          Column() {
            Column() {
              this.nowCard()
            }
            .gesture(LongPressGesture().onAction(() => {
              this.showAddHint = true;
            }))

            Column() {
              this.nextExamCard()
            }
            .gesture(LongPressGesture().onAction(() => {
              this.showAddHint = true;
            }))

            Column() {
              this.coreGpaCard()
            }
            .gesture(LongPressGesture().onAction(() => {
              this.showAddHint = true;
            }))

            Text('长按卡片可查看添加到桌面 / 负一屏的方法')
              .fontSize(9)
              .fontColor($r('app.color.text_faint2'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ top: 4, bottom: 120 })
          }
          .width('100%')
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.TopStart)
      }
    }
    .width('100%')
    .height('100%')
    .bindSheet(this.showAddHint, this.addHintSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: false,
      backgroundColor: $r('app.color.sheet_bg'),
      blurStyle: BlurStyle.COMPONENT_THICK,
      onDisappear: () => {
        this.showAddHint = false;
      }
    })
  }

  @Builder
  addHintSheet() {
    Column() {
      Text('添加到桌面 / 负一屏')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_strong'))

      Text('1. 回到桌面，长按空白处')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ top: 14 })
      Text('2. 点「服务卡片」，找到 SWU教务')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ top: 8 })
      Text('3. 把卡片拖到桌面；负一屏在桌面最左侧一屏')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ top: 8 })

      Text('卡片会展示下一节课和下一场考试，数据随应用同步自动刷新')
        .fontSize(10)
        .fontColor($r('app.color.text_faint2'))
        .width('100%')
        .margin({ top: 14 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 18, right: 18, top: 6, bottom: 28 })
  }

  @Builder
  nextExamCard() {
    Column() {
      Row() {
        Text('下一场考试')
          .fontSize(10)
          .fontColor($r('app.color.on_brand'))
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(8)
          .backgroundColor($r('app.color.brand_text'))

        Blank()

        if (this.nextExam() !== null) {
          Text(this.examDate((this.nextExam() as ExamItem).time))
            .fontSize(26)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.brand_text'))
        }
      }
      .width('100%')

      if (this.nextExam() === null) {
        Text('暂无考试安排')
          .fontSize(14)
          .fontColor($r('app.color.text_tertiary'))
          .margin({ top: 12 })
      } else {
        Text((this.nextExam() as ExamItem).name)
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 8 })

        Row() {
          SymbolGlyph($r('sys.symbol.clock'))
            .fontSize(11)
            .fontColor([$r('app.color.text_hint')])
            .margin({ right: 4 })
          Text(this.examTime((this.nextExam() as ExamItem).time))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
          Blank()
          Text((this.nextExam() as ExamItem).place)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .margin({ top: 8 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .backgroundColor($r('app.color.card_material_bg'))
    .backgroundBlurStyle(BlurStyle.COMPONENT_THIN)
    .border({ width: 0.5, color: $r('app.color.card_border') })
    .borderRadius(12)
    .margin({ left: 12, right: 12, top: 10 })
  }

  @Builder
  coreGpaCard() {
    Column() {
      Row() {
        Text('必修 + 专业选修')
          .fontSize(10)
          .fontColor($r('app.color.on_brand'))
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(8)
          .backgroundColor($r('app.color.brand_text'))
        Blank()
        Text(this.coreGrades().length.toString() + ' 门 · ' + this.coreCredit().toFixed(1) + ' 学分')
          .fontSize(10)
          .fontColor($r('app.color.text_hint'))
      }
      .width('100%')

      Row() {
        Column() {
          Text(this.coreAvg().toFixed(1))
            .fontSize(30)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text('加权平均分')
            .fontSize(10)
            .fontColor($r('app.color.text_hint'))
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Column() {
          Text(this.coreGpa().toFixed(2))
            .fontSize(30)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.success'))
          Text('绩点')
            .fontSize(10)
            .fontColor($r('app.color.text_hint'))
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.End)
      }
      .width('100%')
      .margin({ top: 10 })

      Text('不含国际课程、跨专业选修课')
        .fontSize(9)
        .fontColor($r('app.color.text_faint2'))
        .margin({ top: 8 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .backgroundColor($r('app.color.card_material_bg'))
    .backgroundBlurStyle(BlurStyle.COMPONENT_THIN)
    .border({ width: 0.5, color: $r('app.color.card_border') })
    .borderRadius(12)
    .margin({ left: 12, right: 12, top: 10 })
  }

  /** 右侧自适应悬浮导航：收起是圆形按钮，展开出现「立即同步」 */
  @Builder
  sideRail() {
    Row() {
      Column() {
        if (this.railOpen) {
          Row() {
            SymbolGlyph($r('sys.symbol.arrow_clockwise'))
              .fontSize(14)
              .fontColor([$r('app.color.on_brand')])
              .margin({ right: 6 })
            Text('立即同步')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.on_brand'))
          }
          .height(40)
          .padding({ left: 14, right: 16 })
          .borderRadius(20)
          .backgroundColor($r('app.color.header_material_bg'))
          .backgroundBlurStyle(BlurStyle.COMPONENT_THIN)
          .border({ width: 0.5, color: $r('app.color.card_border') })
          .margin({ bottom: 10 })
          .onClick(() => {
            this.railOpen = false;
            this.openLogin();
          })

          Row() {
            SymbolGlyph($r('sys.symbol.trash'))
              .fontSize(13)
              .fontColor([$r('app.color.danger2')])
              .margin({ right: 5 })
            Text('清空数据')
              .fontSize(12)
              .fontColor($r('app.color.danger2'))
          }
          .height(34)
          .padding({ left: 14, right: 16 })
          .borderRadius(17)
          .backgroundColor($r('app.color.card_material_bg'))
          .backgroundBlurStyle(BlurStyle.COMPONENT_THIN)
          .border({ width: 0.5, color: $r('app.color.card_border') })
          .margin({ bottom: 10 })
          .onClick(() => {
            this.railOpen = false;
            this.confirmClear();
          })
        }

        Row() {
          SymbolGlyph(this.railOpen ? $r('sys.symbol.xmark') : $r('sys.symbol.arrow_clockwise'))
            .fontSize(18)
            .fontColor([$r('app.color.brand_text')])
        }
        .width(44)
        .height(44)
        .justifyContent(FlexAlign.Center)
        .borderRadius(22)
        .backgroundColor($r('app.color.card_material_bg'))
        .backgroundBlurStyle(BlurStyle.COMPONENT_THIN)
        .border({ width: 0.5, color: $r('app.color.card_border') })
        .onClick(() => {
          this.railOpen = !this.railOpen;
        })
      }
      .alignItems(HorizontalAlign.End)
      .margin({ right: 10, bottom: 96 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    .alignItems(VerticalAlign.Bottom)
    .padding({ bottom: this.bottomInset })
  }

  @Builder
  timetablePage() {
    Column() {
      this.headerBar()

      if (this.loading) {
        Column() {
          LoadingProgress().width(30).height(30).color($r('app.color.brand_text'))
          Text('正在加载课表…').fontSize(12).fontColor($r('app.color.text_hint')).margin({ top: 8 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.courses.length === 0) {
        this.pageEmpty($r('sys.symbol.calendar'), '还没有课表', '登录一次教务系统，自动抓取全部学期')
      } else {
        if (this.semesterKey === this.currentSemesterKey()) {
          this.nowCard()
        }

        List() {
          ListItem() {
            this.gridSection()
          }
          ListItem() {
            this.otherHeader()
          }
          ForEach(this.loose, (c: LooseCourse) => {
            ListItem() {
              this.looseCard(c)
            }
            .padding({ left: 14, right: 14 })
          }, (c: LooseCourse) => `${this.semesterKey}_${c.id}`)
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .padding({ top: 8, bottom: 12 })
        .contentEndOffset(60)
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  gradesPage() {
    Column() {
      Row() {
        Column() {
          Text('成绩')
            .fontSize(19)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.on_brand'))
          Text(this.gradeSummary())
            .fontSize(11)
            .fontColor($r('app.color.on_brand_sub'))
            .margin({ top: 2 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Row() {
          Text(this.gradeTerm === '' ? '全部学期' : this.gradeTerm)
            .fontSize(10)
            .fontColor($r('app.color.on_brand_chip_text'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          SymbolGlyph($r('sys.symbol.chevron_down'))
            .fontSize(9)
            .fontColor([$r('app.color.on_brand_chip_text')])
            .margin({ left: 3 })
        }
        .constraintSize({ maxWidth: 150 })
        .padding({ left: 10, right: 8, top: 6, bottom: 6 })
        .borderRadius(13)
        .backgroundColor($r('app.color.on_brand_chip'))
        .margin({ right: 8 })
        .onClick(() => {
          this.showGradeTerm = true;
        })
      }
      .width('100%')
      .padding({ left: 16, right: 14, top: this.topInset + 14, bottom: 12 })
      .backgroundColor($r('app.color.header_material_bg'))
      .border({ width: { bottom: 0.5 }, color: $r('app.color.card_border') })
      .bindSheet(this.showGradeTerm, this.termSheet(true), {
        height: SheetSize.FIT_CONTENT,
        dragBar: true,
        showClose: false,
        backgroundColor: $r('app.color.sheet_bg'),
        blurStyle: BlurStyle.COMPONENT_THICK,
        onDisappear: () => {
          this.showGradeTerm = false;
        }
      })

      if (this.grades.length === 0) {
        this.pageEmpty($r('sys.symbol.graduationcap'), '还没有成绩', '登录一次教务系统，自动抓取全部学期成绩')
      } else {
        List() {
          ForEach(this.gradeRows(), (r: GradeRow) => {
            ListItem() {
              if (r.kind === 'term') {
                Row() {
                  Text(r.term)
                    .fontSize(12)
                    .fontWeight(FontWeight.Bold)
                    .fontColor($r('app.color.text_secondary'))
                  Blank()
                  Text(r.summary)
                    .fontSize(10)
                    .fontColor($r('app.color.text_hint'))
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 14, bottom: 6 })
              } else {
                this.gradeRow(r)
              }
            }
          }, (r: GradeRow) => `${r.kind}_${r.term}_${r.name}`)
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .padding({ left: 14, right: 14, bottom: 12 })
        .contentEndOffset(60)
      }
    }
    .width('100%')
    .height('100%')
    .bindSheet(this.showGradeDetail, this.gradeDetailSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: false,
      backgroundColor: $r('app.color.sheet_bg'),
        blurStyle: BlurStyle.COMPONENT_THICK,
      onDisappear: () => {
        this.showGradeDetail = false;
        this.selGrade = null;
      }
    })
  }

  @Builder
  gradeRow(r: GradeRow) {
    Row() {
      Column() {
        Text(r.name)
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`${r.credit} 学分 · ${r.nature}`)
          .fontSize(10)
          .fontColor($r('app.color.text_faint'))
          .margin({ top: 3 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Column() {
        Text(r.score)
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.scoreColor(r.score))
        Text(`绩点 ${r.gpa}`)
          .fontSize(9)
          .fontColor($r('app.color.text_faint'))
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.End)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 11, bottom: 11 })
    .backgroundColor($r('app.color.card_material_bg'))
    .backgroundBlurStyle(BlurStyle.COMPONENT_THIN)
    .border({ width: 0.5, color: $r('app.color.card_border') })
    .borderRadius(10)
    .margin({ bottom: 8 })
    .onClick(() => {
      this.selGrade = r;
      this.showGradeDetail = true;
    })
  }

  @Builder
  loginCover() {
    SyncPage({
      onSynced: () => {
        // 只刷新数据，浮层留在结果页，由"查看课表"关闭
        this.reload();
      },
      onCleared: () => {
        this.courses = [];
        this.loose = [];
        this.semesters = [];
        this.grades = [];
        this.exams = [];
        this.gradeTerm = '';
        this.examTerm = '';
        this.semesterKey = '';
        this.semester = '';
        this.sourceLabel = '';
        this.lastSyncAt = '';
        this.reload();
      },
      onClose: () => {
        this.closeLogin();
      },
      onDone: () => {
        this.closeLogin();
        this.tab = 0;
        this.hdsController.changeIndex(0);
        this.reload();
      }
    })
  }

  private openLogin(): void {
    AppStorage.setOrCreate('overlayOpen', true);
    this.showLogin = true;
  }

  private closeLogin(): void {
    this.showLogin = false;
    AppStorage.setOrCreate('overlayOpen', false);
  }

  onBackPress(): boolean {
    if (this.showLogin) {
      this.closeLogin();
      return true;
    }
    if (this.sheetShow || this.showSemester || this.showGradeTerm || this.showExamTerm
      || this.showGradeDetail || this.showExamDetail) {
      this.sheetShow = false;
      this.showSemester = false;
      this.showGradeTerm = false;
      this.showExamTerm = false;
      this.showGradeDetail = false;
      this.showExamDetail = false;
      return true;
    }
    return false;
  }

  /** 系统返回键：先关浮层/弹层，再交给系统 */
  onBackTick(): void {
    if (this.showLogin) {
      this.closeLogin();
      return;
    }
    if (this.sheetShow || this.showSemester || this.showGradeTerm || this.showExamTerm
      || this.showGradeDetail || this.showExamDetail) {
      this.sheetShow = false;
      this.showSemester = false;
      this.showGradeTerm = false;
      this.showExamTerm = false;
      this.showGradeDetail = false;
      this.showExamDetail = false;
    }
  }

  private syncLabel(): string {
    if (this.lastSyncAt === '') {
      return '还没有同步过';
    }
    const d = new Date(this.lastSyncAt);
    if (isNaN(d.getTime())) {
      return '已同步';
    }
    const pad = (n: number): string => n < 10 ? '0' + n.toString() : n.toString();
    return '上次同步：' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
  }

  private confirmClear(): void {
    this.getUIContext().showAlertDialog({
      title: '清空本地数据',
      message: '将删除本机缓存的课表、成绩、考试和登录状态，需要重新登录才能同步。确定清空？',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清空',
        fontColor: $r('app.color.danger'),
        action: () => {
          this.clearAllData();
        }
      }
    });
  }

  private async clearAllData(): Promise<void> {
    const ctx: common.UIAbilityContext | null = this.ctxOrNull();
    if (ctx !== null) {
      await TimetableRepo.clear(ctx);
    }
    try {
      webview.WebCookieManager.clearAllCookiesSync(false);
    } catch (err) {
      // 忽略
    }
    this.courses = [];
    this.loose = [];
    this.semesters = [];
    this.grades = [];
    this.exams = [];
    this.gradeTerm = '';
    this.examTerm = '';
    this.semesterKey = '';
    this.semester = '';
    this.sourceLabel = '';
    this.lastSyncAt = '';
  }

  @Builder
  gradeDetailSheet() {
    Column() {
      if (this.selGrade !== null) {
        Text((this.selGrade as GradeRow).name)
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_strong'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text((this.selGrade as GradeRow).term)
          .fontSize(11)
          .fontColor($r('app.color.text_hint'))
          .margin({ top: 6 })

        Row() {
          Text((this.selGrade as GradeRow).score)
            .fontSize(34)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.scoreColor((this.selGrade as GradeRow).score))
          Text('分')
            .fontSize(12)
            .fontColor($r('app.color.text_hint'))
            .margin({ left: 4, bottom: 6 })
          Blank()
          Column() {
            Text(`绩点 ${(this.selGrade as GradeRow).gpa}`)
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
            Text(`${(this.selGrade as GradeRow).credit} 学分`)
              .fontSize(11)
              .fontColor($r('app.color.text_hint'))
              .margin({ top: 3 })
          }
          .alignItems(HorizontalAlign.End)
        }
        .width('100%')
        .margin({ top: 10 })

        Divider().color($r('app.color.divider')).margin({ top: 12, bottom: 10 })

        Row() {
          Text('课程性质').fontSize(12).fontColor($r('app.color.text_hint')).width(72)
          Text((this.selGrade as GradeRow).nature)
            .fontSize(13).fontColor($r('app.color.text_secondary')).layoutWeight(1)
        }.width('100%')

        Row() {
          Text('任课教师').fontSize(12).fontColor($r('app.color.text_hint')).width(72)
          Text((this.selGrade as GradeRow).teacher)
            .fontSize(13).fontColor($r('app.color.text_secondary')).layoutWeight(1)
        }.width('100%').margin({ top: 8 })

        Row() {
          Text('考核方式').fontSize(12).fontColor($r('app.color.text_hint')).width(72)
          Text((this.selGrade as GradeRow).examType)
            .fontSize(13).fontColor($r('app.color.text_secondary')).layoutWeight(1)
        }.width('100%').margin({ top: 8 })

        Text('平时/期末等分项成绩需在教务「成绩明细查询」查看')
          .fontSize(9)
          .fontColor($r('app.color.text_faint2'))
          .margin({ top: 14 })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 24 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  examDetailSheet() {
    Column() {
      if (this.selExam !== null) {
        Text((this.selExam as ExamItem).name)
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_strong'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text((this.selExam as ExamItem).examName)
          .fontSize(11)
          .fontColor($r('app.color.text_hint'))
          .margin({ top: 6 })

        Row() {
          Column() {
            Text(this.examDate((this.selExam as ExamItem).time))
              .fontSize(28)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.brand_text'))
            Text('考试日期')
              .fontSize(9)
              .fontColor($r('app.color.text_faint'))
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)

          Blank()

          Column() {
            Text(this.examTime((this.selExam as ExamItem).time))
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
            Text('考试时段')
              .fontSize(9)
              .fontColor($r('app.color.text_faint'))
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.End)
        }
        .width('100%')
        .margin({ top: 12 })

        Divider().color($r('app.color.divider')).margin({ top: 14, bottom: 10 })

        Row() {
          Text('考场').fontSize(12).fontColor($r('app.color.text_hint')).width(72)
          Text((this.selExam as ExamItem).place)
            .fontSize(13).fontColor($r('app.color.text_secondary')).layoutWeight(1)
        }.width('100%')

        Row() {
          Text('教师').fontSize(12).fontColor($r('app.color.text_hint')).width(72)
          Text((this.selExam as ExamItem).teacher)
            .fontSize(13).fontColor($r('app.color.text_secondary')).layoutWeight(1)
        }.width('100%').margin({ top: 8 })

        Row() {
          Text('学期').fontSize(12).fontColor($r('app.color.text_hint')).width(72)
          Text((this.selExam as ExamItem).term)
            .fontSize(13).fontColor($r('app.color.text_secondary')).layoutWeight(1)
        }.width('100%').margin({ top: 8 })

        Text('具体座位号请以教务系统公布的考场安排为准')
          .fontSize(9)
          .fontColor($r('app.color.text_faint2'))
          .margin({ top: 14 })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 24 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  examsPage() {
    Column() {
      Row() {
        Column() {
          Text('考试')
            .fontSize(19)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.on_brand'))
          Text(this.examSummary())
            .fontSize(11)
            .fontColor($r('app.color.on_brand_sub'))
            .margin({ top: 2 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Row() {
          Text(this.examTerm === '' ? '全部学期' : this.examTerm)
            .fontSize(10)
            .fontColor($r('app.color.on_brand_chip_text'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          SymbolGlyph($r('sys.symbol.chevron_down'))
            .fontSize(9)
            .fontColor([$r('app.color.on_brand_chip_text')])
            .margin({ left: 3 })
        }
        .constraintSize({ maxWidth: 150 })
        .padding({ left: 10, right: 8, top: 6, bottom: 6 })
        .borderRadius(13)
        .backgroundColor($r('app.color.on_brand_chip'))
        .margin({ right: 8 })
        .onClick(() => {
          this.showExamTerm = true;
        })
      }
      .width('100%')
      .padding({ left: 16, right: 14, top: this.topInset + 14, bottom: 12 })
      .backgroundColor($r('app.color.header_material_bg'))
      .border({ width: { bottom: 0.5 }, color: $r('app.color.card_border') })
      .bindSheet(this.showExamTerm, this.termSheet(false), {
        height: SheetSize.FIT_CONTENT,
        dragBar: true,
        showClose: false,
        backgroundColor: $r('app.color.sheet_bg'),
        blurStyle: BlurStyle.COMPONENT_THICK,
        onDisappear: () => {
          this.showExamTerm = false;
        }
      })

      if (this.exams.length === 0) {
        this.pageEmpty($r('sys.symbol.doc_text'), '还没有考试安排', '期末考试排出来后同步一次即可')
      } else {
        List() {
          ForEach(this.examsFiltered(), (it: ExamItem) => {
            ListItem() {
              this.examRow(it)
            }
          }, (it: ExamItem) => `${this.examTerm}_${it.term}_${it.name}_${it.time}`)
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .padding({ left: 14, right: 14, top: 8, bottom: 12 })
        .contentEndOffset(60)
      }
    }
    .width('100%')
    .height('100%')
    .bindSheet(this.showExamDetail, this.examDetailSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: false,
      backgroundColor: $r('app.color.sheet_bg'),
        blurStyle: BlurStyle.COMPONENT_THICK,
      onDisappear: () => {
        this.showExamDetail = false;
        this.selExam = null;
      }
    })
  }

  @Builder
  examRow(it: ExamItem) {
    Column() {
      Row() {
        Text(it.name)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.examDate(it.time))
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.brand_text'))
      }
      .width('100%')

      Row() {
        SymbolGlyph($r('sys.symbol.clock'))
          .fontSize(10)
          .fontColor([$r('app.color.text_faint')])
          .margin({ right: 3 })
        Text(this.examTime(it.time))
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
        Blank()
        Text(it.place)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .margin({ top: 6 })

      Text(it.examName)
        .fontSize(9)
        .fontColor($r('app.color.text_faint2'))
        .margin({ top: 4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .backgroundColor($r('app.color.card_material_bg'))
    .backgroundBlurStyle(BlurStyle.COMPONENT_THIN)
    .border({ width: 0.5, color: $r('app.color.card_border') })
    .borderRadius(10)
    .margin({ bottom: 8 })
    .onClick(() => {
      this.selExam = it;
      this.showExamDetail = true;
    })
  }

  /** Tab 图标（参考项目同款：选中态主色 + 中等字重） */
  @Builder
  tabIcon(iconNormal: Resource, iconSelected: Resource, label: string, idx: number) {
    Column({ space: 2 }) {
      SymbolGlyph(this.tab === idx ? iconSelected : iconNormal)
        .fontSize(21)
        .fontColor(this.tab === idx ? [$r('app.color.brand_text')] : [$r('app.color.text_hint')])
      Text(label)
        .fontSize(10)
        .fontWeight(this.tab === idx ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.tab === idx ? $r('app.color.brand_text') : $r('app.color.text_hint'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.hdsController.changeIndex(idx);
    })
  }

  @Builder
  headerBar() {
    Column() {
      Row() {
        Column() {
          Text('课程表')
            .fontSize(19)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.on_brand'))
          Text(this.timetableSubtitle())
            .fontSize(11)
            .fontColor($r('app.color.on_brand_sub'))
            .margin({ top: 2 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Row() {
          Text(this.semester === '' ? '选择学期' : this.semester)
            .fontSize(10)
            .fontColor($r('app.color.on_brand_chip_text'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          SymbolGlyph($r('sys.symbol.chevron_down'))
            .fontSize(9)
            .fontColor([$r('app.color.on_brand_chip_text')])
            .margin({ left: 3 })
        }
        .constraintSize({ maxWidth: 150 })
        .padding({ left: 10, right: 8, top: 6, bottom: 6 })
        .borderRadius(13)
        .backgroundColor($r('app.color.on_brand_chip'))
        .onClick(() => {
          this.showSemester = true;
        })
      }
      .width('100%')
      .padding({ left: 16, right: 14, top: 14, bottom: 12 })

      Row() {
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(13)
            .fontColor([$r('app.color.on_brand_chip_text')])
        }
        .width(26)
        .height(26)
        .justifyContent(FlexAlign.Center)
        .borderRadius(13)
        .backgroundColor($r('app.color.on_brand_chip'))
        .onClick(() => {
          this.step(-1);
        })

        Column() {
          Text(`第 ${this.week} 周`)
            .fontSize(12)
            .fontColor($r('app.color.on_brand'))
          Text(this.weekRange())
            .fontSize(9)
            .fontColor($r('app.color.on_brand_sub2'))
            .margin({ top: 1 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)

        Row() {
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(13)
            .fontColor([$r('app.color.on_brand_chip_text')])
        }
        .width(26)
        .height(26)
        .justifyContent(FlexAlign.Center)
        .borderRadius(13)
        .backgroundColor($r('app.color.on_brand_chip'))
        .onClick(() => {
          this.step(1);
        })

        Row() {
          SymbolGlyph($r('sys.symbol.calendar'))
            .fontSize(10)
            .fontColor([$r('app.color.on_brand_chip_text')])
            .margin({ right: 3 })
          Text(this.semesterKey === this.currentSemesterKey() ? '本周' : '第 1 周')
            .fontSize(10)
            .fontColor($r('app.color.on_brand_chip_text'))
        }
        .padding({ left: 8, right: 9, top: 4, bottom: 4 })
        .borderRadius(12)
        .backgroundColor($r('app.color.on_brand_chip'))
        .margin({ left: 8 })
        .onClick(() => {
          this.week = this.currentWeek();
          this.selected = null;
          this.refreshNow();
        })
      }
      .width('100%')
      .padding({ left: 16, right: 14, bottom: 12 })
      .visibility(this.courses.length > 0 ? Visibility.Visible : Visibility.None)
    }
    .width('100%')
    .padding({ top: this.topInset })
    .backgroundColor($r('app.color.header_material_bg'))
      .border({ width: { bottom: 0.5 }, color: $r('app.color.card_border') })
    .bindSheet(this.showSemester, this.semesterSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: false,
      backgroundColor: $r('app.color.sheet_bg'),
        blurStyle: BlurStyle.COMPONENT_THICK,
      onDisappear: () => {
        this.showSemester = false;
      }
    })
  }

  @Builder
  semesterSheet() {
    Column() {
      Text('切换学期')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_strong'))
        .margin({ bottom: 6 })

      List() {
        ForEach(this.semesters, (s: SemesterRef) => {
          ListItem() {
            Row() {
              Column() {
                Text(s.label)
                  .fontSize(14)
                  .fontWeight(s.key === this.semesterKey ? FontWeight.Bold : FontWeight.Normal)
                  .fontColor(s.key === this.semesterKey ? $r('app.color.brand_text') : $r('app.color.text_secondary'))
                Text(`${s.courseCount} 门课 · ${this.semesterTag(s)}`)
                  .fontSize(10)
                  .fontColor($r('app.color.text_hint'))
                  .margin({ top: 2 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              if (s.key === this.semesterKey) {
                Text('当前')
                  .fontSize(10)
                  .fontColor($r('app.color.on_brand'))
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                  .borderRadius(8)
                  .backgroundColor($r('app.color.brand_text'))

              }
            }
            .width('100%')
            .padding({ top: 10, bottom: 10 })
          }
          .onClick(() => {
            this.showSemester = false;
            this.applySemester(s.key);
          })
        }, (s: SemesterRef) => s.key)
      }
      .height(this.semesters.length * 62)
      .scrollBar(BarState.Off)

      Divider().color($r('app.color.divider')).margin({ top: 2, bottom: 2 })

      Row() {
        Text('清空本地缓存数据')
          .fontSize(13)
          .fontColor($r('app.color.danger2'))
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ top: 12, bottom: 14 })
      .onClick(() => {
        this.clearAll();
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 4, bottom: 16 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  nowCard() {
    Column() {
      Row() {
        Text(this.nowTag())
          .fontSize(10)
          .fontColor($r('app.color.on_brand'))
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(9)
          .backgroundColor(this.nowColor())
        Blank()
        Text(this.updatedAt === '' ? '' : `数据 ${this.updatedAt}`)
          .fontSize(10)
          .fontColor($r('app.color.text_faint'))
      }
      .width('100%')

      Text(this.nowTitle())
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_strong'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 8 })

      Text(this.nowSub())
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 3 })

      Row() {
        Text(this.nowTail())
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.nowColor())
        Blank()
        Text(this.nowRange())
          .fontSize(10)
          .fontColor($r('app.color.text_faint'))
      }
      .width('100%')
      .margin({ top: 8 })
    }
    .width('100%')
    .padding(14)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.card_material_bg'))
    .backgroundBlurStyle(BlurStyle.COMPONENT_THIN)
    .border({ width: 0.5, color: $r('app.color.card_border') })
    .borderRadius(12)
    .margin({ left: 12, right: 12, top: 10 })
    .visualEffect(this.cardLight)
  }

  /** 三个页签共用的空态：图标卡片 + 标题 + 说明 + 同步按钮 + 隐私说明 */
  @Builder
  pageEmpty(icon: Resource, title: string, hint: string) {
    Column() {
      Column() {
        SymbolGlyph(icon)
          .fontSize(40)
          .fontColor([$r('app.color.icon_card_fg')])
      }
      .width(76)
      .height(76)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .borderRadius(20)
      .backgroundColor($r('app.color.icon_card_bg'))

      Text(title)
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .margin({ top: 18 })

      Text(hint)
        .fontSize(11)
        .fontColor($r('app.color.text_hint'))
        .textAlign(TextAlign.Center)
        .margin({ top: 8 })

      Row() {
        Text('从教务系统同步')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_brand'))
      }
      .padding({ left: 26, right: 26, top: 11, bottom: 11 })
      .borderRadius(22)
      .backgroundColor($r('app.color.header_material_bg'))
      .backgroundBlurStyle(BlurStyle.COMPONENT_THIN)
      .border({ width: 0.5, color: $r('app.color.card_border') })
      .margin({ top: 22 })
      .onClick(() => {
        this.openLogin();
      })

      Text('数据只存在本机，不经过任何服务器')
        .fontSize(9)
        .fontColor($r('app.color.text_faint2'))
        .margin({ top: 14 })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  gridSection() {
    Row() {
      this.timeColumn()
      Scroll() {
        this.daysGrid()
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .align(Alignment.TopStart)
    }
    .alignItems(VerticalAlign.Top)
    .padding({ left: 8, right: 8 })
    .gesture(
      GestureGroup(GestureMode.Parallel,
        TapGesture({ count: 2 })
          .onAction(() => {
            this.applyZoom(1);
          }),
        PinchGesture({ fingers: 2 })
          .onActionStart(() => {
            this.baseZoom = this.zoom;
          })
          .onActionUpdate((event: GestureEvent) => {
            this.applyZoom(this.baseZoom * event.scale);
          })
      )
    )
  }

  @Builder
  timeColumn() {
    Column() {
      Text('')
        .height(this.headH)
        .width(this.timeW)
      ForEach(PERIODS, (p: Period) => {
        Column() {
          Text(`${p.index}`)
            .fontSize(11)
            .fontColor($r('app.color.text_hint'))
          Text(p.start)
            .fontSize(8)
            .fontColor($r('app.color.text_faint3'))
            .margin({ top: 1 })
        }
        .height(this.rowH)
        .width(this.timeW)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }, (p: Period) => `time_${this.zoom}_${p.index}`)
    }
    .width(this.timeW)
  }

  @Builder
  daysGrid() {
    Column() {
      Row() {
        ForEach(WEEKDAYS, (w: Weekday) => {
          Column() {
            Text(`周${w.label}`)
              .fontSize(12)
              .fontWeight(this.today() === w.index ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(this.today() === w.index ? $r('app.color.brand_text') : $r('app.color.text_dim'))
          }
          .width(this.colW)
          .height(this.headH)
          .justifyContent(FlexAlign.Center)
          .backgroundColor(this.today() === w.index ? $r('app.color.cell_today') : $r('app.color.surface'))
        }, (w: Weekday) => `head_${this.zoom}_${w.index}`)
      }

      Row() {
        ForEach(WEEKDAYS, (w: Weekday) => {
          this.dayColumn(w.index)
        }, (w: Weekday) => `col_${this.zoom}_${w.index}`)
      }
      .alignItems(VerticalAlign.Top)
    }
  }

  @Builder
  dayColumn(day: number) {
    Column() {
      ForEach(this.layout(day), (s: Slot) => {
        Stack() {
          if (s.course !== null) {
            this.courseCard(s.course as Course)
          } else {
            Column()
              .width('100%')
              .height('100%')
              .backgroundColor(day >= 6 ? $r('app.color.grid_empty') : $r('app.color.surface'))
              .borderRadius(5)
          }
        }
        .width('100%')
        .height(s.span * this.rowH)
        .padding(1)
      }, (s: Slot) => `${this.week}_${this.zoom}_${day}_${s.period}_${s.course === null ? 'x' : s.course.id}`)
    }
    .width(this.colW)
  }

  @Builder
  courseCard(c: Course) {
    Column() {
      Text(c.name)
        .fontSize(this.nameFont())
        .lineHeight(this.nameFont() * 1.3)
        .fontColor(c.practice ? $r('app.color.course_practice_text') : $r('app.color.course_text'))
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(c.location)
        .fontSize(this.locFont())
        .fontColor(c.practice ? $r('app.color.course_practice_loc') : $r('app.color.course_loc'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 2 })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 4, right: 4, top: 4, bottom: 3 })
    .justifyContent(FlexAlign.SpaceBetween)
    .alignItems(HorizontalAlign.Start)
    .borderRadius(5)
    .backgroundColor(c.practice ? $r('app.color.success_bg') : $r('app.color.info_bg'))
    .onClick(() => {
      this.selected = c;
      this.sheetShow = true;
    })
  }

  @Builder
  otherHeader() {
    Row() {
      Text('其它课程')
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_secondary'))
      Blank()
      Text('◇ 讲课   ◆ 实践/实验')
        .fontSize(9)
        .fontColor($r('app.color.text_hint'))
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 8 })
  }

  @Builder
  looseCard(c: LooseCourse) {
    Column() {
      Row() {
        Text(c.name)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)
        Text(c.weeks)
          .fontSize(10)
          .fontColor($r('app.color.brand_text'))
      }
      .width('100%')
      Row() {
        Text(c.teacher)
          .fontSize(10)
          .fontColor($r('app.color.text_hint'))
          .layoutWeight(1)
        Text(c.note)
          .fontSize(9)
          .fontColor($r('app.color.warn'))
      }
      .width('100%')
      .margin({ top: 2 })
    }
    .width('100%')
    .padding(10)
    .margin({ bottom: 8 })
    .backgroundColor($r('app.color.card_material_bg'))
    .backgroundBlurStyle(BlurStyle.COMPONENT_THIN)
    .border({ width: 0.5, color: $r('app.color.card_border') })
    .borderRadius(8)
  }

  @Builder
  detailSheet() {
    Column() {
      if (this.selected !== null) {
        this.detailBody(this.selected as Course)
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 4, bottom: 20 })
  }

  @Builder
  detailBody(c: Course) {
    Column() {
      Row() {
        Text(c.name)
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_strong'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(15)
          .fontColor([$r('app.color.text_hint')])
          .margin({ left: 8 })
          .onClick(() => {
            this.sheetShow = false;
          })
      }
      .width('100%')

      Text(this.selWeekHint())
        .fontSize(11)
        .fontColor(c.practice ? $r('app.color.success_text') : $r('app.color.brand_text'))
        .margin({ top: 6 })

      Divider().color($r('app.color.divider')).margin({ top: 12, bottom: 12 })

      Row() {
        Text('时间').fontSize(12).fontColor($r('app.color.text_hint')).width(52)
        Text(`${weekdayLabel(c.weekday)} ${c.start}-${c.end} 节`)
          .fontSize(13).fontColor($r('app.color.text_secondary')).layoutWeight(1)
      }
      .width('100%')

      Row() {
        Text('作息').fontSize(12).fontColor($r('app.color.text_hint')).width(52)
        Text(timeRange(c.start, c.end)).fontSize(13).fontColor($r('app.color.text_secondary')).layoutWeight(1)
      }
      .width('100%')
      .margin({ top: 10 })

      Row() {
        Text('地点').fontSize(12).fontColor($r('app.color.text_hint')).width(52)
        Text(c.location).fontSize(13).fontColor($r('app.color.text_secondary')).layoutWeight(1)
      }
      .width('100%')
      .margin({ top: 10 })

      Row() {
        Text('教师').fontSize(12).fontColor($r('app.color.text_hint')).width(52)
        Text(c.teacher).fontSize(13).fontColor($r('app.color.text_secondary')).layoutWeight(1)
      }
      .width('100%')
      .margin({ top: 10 })

      Row() {
        Text('周次').fontSize(12).fontColor($r('app.color.text_hint')).width(52)
        Text(weeksLabel(c.weeks)).fontSize(13).fontColor($r('app.color.text_secondary')).layoutWeight(1)
      }
      .width('100%')
      .margin({ top: 10 })

      if (c.note !== '') {
        Row() {
          Text('备注').fontSize(12).fontColor($r('app.color.text_hint')).width(52)
          Text(c.note).fontSize(12).fontColor($r('app.color.warn')).layoutWeight(1)
        }
        .width('100%')
        .margin({ top: 10 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
