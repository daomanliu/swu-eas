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
import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
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
  @State selExam: ExamItem | null = null;
  @State showExamDetail: boolean = false;

  private material: uiMaterial.ImmersiveMaterial | undefined = undefined;
  private hdsController: HdsTabsController = new HdsTabsController();
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
  private static readonly BASE_NAME_FONT: number = 10;
  private static readonly BASE_LOC_FONT: number = 8;

  /** 缩放只改列宽/行高/字号，文字保持矢量清晰 */
  private applyZoom(z: number): void {
    const clamped: number = Math.min(Index.MAX_ZOOM, Math.max(Index.MIN_ZOOM, z));
    this.zoom = clamped;
    this.colW = Index.BASE_COL * clamped;
    this.rowH = Index.BASE_ROW * clamped;
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

  private nowColor(): string {
    if (this.nowItem.kind === 'now') {
      return '#19A461';
    }
    if (this.nowItem.kind === 'next') {
      return '#1E4E8C';
    }
    return '#8A94A6';
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
      return '未同步';
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

  private scoreColor(score: string): string {
    const s: number = Number(score);
    if (isNaN(s)) {
      return '#26313F';
    }
    if (s >= 90) {
      return '#19A461';
    }
    if (s >= 60) {
      return '#26313F';
    }
    return '#C0392B';
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
        .fontColor('#16233A')
        .margin({ bottom: 6 })

      List() {
        ForEach(isGrade ? this.gradeTerms() : this.examTerms(), (t: string) => {
          ListItem() {
            Row() {
              Text(t === '' ? '全部学期' : t)
                .fontSize(14)
                .fontColor('#3A4657')
                .layoutWeight(1)
              if (t === (isGrade ? this.gradeTerm : this.examTerm)) {
                Text('当前')
                  .fontSize(10)
                  .fontColor('#FFFFFF')
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                  .borderRadius(8)
                  .backgroundColor('#1E4E8C')
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
          this.timetablePage()
        }
        .tabBar(this.tabIcon($r('sys.symbol.calendar'), $r('sys.symbol.calendar'), '课表', 0))

        TabContent() {
          this.gradesPage()
        }
        .tabBar(this.tabIcon($r('sys.symbol.graduationcap'), $r('sys.symbol.graduationcap'), '成绩', 1))

        TabContent() {
          this.examsPage()
        }
        .tabBar(this.tabIcon($r('sys.symbol.doc_text'), $r('sys.symbol.doc_text'), '考试', 2))

        TabContent() {
          Column()
            .width('100%')
            .height('100%')
        }
        .tabBar(this.tabIcon($r('sys.symbol.arrow_clockwise'), $r('sys.symbol.arrow_clockwise'), '同步', 3))
      }
      .barOverlap(true)
      .barPosition(BarPosition.End)
      .barFloatingStyle({
        barSideMargin: 16,
        barBottomMargin: 12,
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      })
      .onChange((index: number) => {
        this.tab = index === 3 ? 0 : index;
        if (index === 3) {
          this.hdsController.changeIndex(0);
          router.pushUrl({ url: 'pages/SyncPage' });
        }
      })
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F2F4F7')
    .bindSheet(this.sheetShow, this.detailSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: false,
      backgroundColor: '#FFFFFF',
      onDisappear: () => {
        this.sheetShow = false;
        this.selected = null;
      }
    })
  }

  @Builder
  timetablePage() {
    Column() {
      this.headerBar()

      if (this.loading) {
        Column() {
          LoadingProgress().width(30).height(30).color('#1E4E8C')
          Text('正在加载课表…').fontSize(12).fontColor('#8A94A6').margin({ top: 8 })
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
        .padding({ top: 8, bottom: 120 })
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
            .fontColor('#FFFFFF')
          Text(this.gradeSummary())
            .fontSize(11)
            .fontColor('#BFD2EA')
            .margin({ top: 2 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Row() {
          Text(this.gradeTerm === '' ? '全部学期' : this.gradeTerm)
            .fontSize(10)
            .fontColor('#CFE0F5')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          SymbolGlyph($r('sys.symbol.chevron_down'))
            .fontSize(9)
            .fontColor(['#CFE0F5'])
            .margin({ left: 3 })
        }
        .constraintSize({ maxWidth: 150 })
        .padding({ left: 10, right: 8, top: 6, bottom: 6 })
        .borderRadius(13)
        .backgroundColor('#2F63A8')
        .margin({ right: 8 })
        .onClick(() => {
          this.showGradeTerm = true;
        })
      }
      .width('100%')
      .padding({ left: 16, right: 14, top: 14, bottom: 12 })
      .backgroundColor('#1E4E8C')
      .bindSheet(this.showGradeTerm, this.termSheet(true), {
        height: SheetSize.FIT_CONTENT,
        dragBar: true,
        showClose: false,
        backgroundColor: '#FFFFFF',
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
                    .fontColor('#3A4657')
                  Blank()
                  Text(r.summary)
                    .fontSize(10)
                    .fontColor('#8A94A6')
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
        .padding({ left: 14, right: 14, bottom: 120 })
      }
    }
    .width('100%')
    .height('100%')
    .bindSheet(this.showGradeDetail, this.gradeDetailSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: false,
      backgroundColor: '#FFFFFF',
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
          .fontColor('#26313F')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`${r.credit} 学分 · ${r.nature}`)
          .fontSize(10)
          .fontColor('#9AA4B2')
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
          .fontColor('#9AA4B2')
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.End)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 11, bottom: 11 })
    .backgroundColor('#FFFFFF')
    .borderRadius(10)
    .margin({ bottom: 8 })
    .onClick(() => {
      this.selGrade = r;
      this.showGradeDetail = true;
    })
  }

  @Builder
  gradeDetailSheet() {
    Column() {
      if (this.selGrade !== null) {
        Text((this.selGrade as GradeRow).name)
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor('#16233A')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text((this.selGrade as GradeRow).term)
          .fontSize(11)
          .fontColor('#8A94A6')
          .margin({ top: 6 })

        Row() {
          Text((this.selGrade as GradeRow).score)
            .fontSize(34)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.scoreColor((this.selGrade as GradeRow).score))
          Text('分')
            .fontSize(12)
            .fontColor('#8A94A6')
            .margin({ left: 4, bottom: 6 })
          Blank()
          Column() {
            Text(`绩点 ${(this.selGrade as GradeRow).gpa}`)
              .fontSize(13)
              .fontColor('#3A4657')
            Text(`${(this.selGrade as GradeRow).credit} 学分`)
              .fontSize(11)
              .fontColor('#8A94A6')
              .margin({ top: 3 })
          }
          .alignItems(HorizontalAlign.End)
        }
        .width('100%')
        .margin({ top: 10 })

        Divider().color('#EEF1F5').margin({ top: 12, bottom: 10 })

        Row() {
          Text('课程性质').fontSize(12).fontColor('#8A94A6').width(72)
          Text((this.selGrade as GradeRow).nature)
            .fontSize(13).fontColor('#3A4657').layoutWeight(1)
        }.width('100%')

        Row() {
          Text('任课教师').fontSize(12).fontColor('#8A94A6').width(72)
          Text((this.selGrade as GradeRow).teacher)
            .fontSize(13).fontColor('#3A4657').layoutWeight(1)
        }.width('100%').margin({ top: 8 })

        Row() {
          Text('考核方式').fontSize(12).fontColor('#8A94A6').width(72)
          Text((this.selGrade as GradeRow).examType)
            .fontSize(13).fontColor('#3A4657').layoutWeight(1)
        }.width('100%').margin({ top: 8 })

        Text('平时/期末等分项成绩需在教务「成绩明细查询」查看')
          .fontSize(9)
          .fontColor('#B0B8C4')
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
          .fontColor('#16233A')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text((this.selExam as ExamItem).examName)
          .fontSize(11)
          .fontColor('#8A94A6')
          .margin({ top: 6 })

        Row() {
          Column() {
            Text(this.examDate((this.selExam as ExamItem).time))
              .fontSize(28)
              .fontWeight(FontWeight.Bold)
              .fontColor('#1E4E8C')
            Text('考试日期')
              .fontSize(9)
              .fontColor('#9AA4B2')
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)

          Blank()

          Column() {
            Text(this.examTime((this.selExam as ExamItem).time))
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor('#26313F')
            Text('考试时段')
              .fontSize(9)
              .fontColor('#9AA4B2')
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.End)
        }
        .width('100%')
        .margin({ top: 12 })

        Divider().color('#EEF1F5').margin({ top: 14, bottom: 10 })

        Row() {
          Text('考场').fontSize(12).fontColor('#8A94A6').width(72)
          Text((this.selExam as ExamItem).place)
            .fontSize(13).fontColor('#3A4657').layoutWeight(1)
        }.width('100%')

        Row() {
          Text('教师').fontSize(12).fontColor('#8A94A6').width(72)
          Text((this.selExam as ExamItem).teacher)
            .fontSize(13).fontColor('#3A4657').layoutWeight(1)
        }.width('100%').margin({ top: 8 })

        Row() {
          Text('学期').fontSize(12).fontColor('#8A94A6').width(72)
          Text((this.selExam as ExamItem).term)
            .fontSize(13).fontColor('#3A4657').layoutWeight(1)
        }.width('100%').margin({ top: 8 })

        Text('具体座位号请以教务系统公布的考场安排为准')
          .fontSize(9)
          .fontColor('#B0B8C4')
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
            .fontColor('#FFFFFF')
          Text(this.examSummary())
            .fontSize(11)
            .fontColor('#BFD2EA')
            .margin({ top: 2 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Row() {
          Text(this.examTerm === '' ? '全部学期' : this.examTerm)
            .fontSize(10)
            .fontColor('#CFE0F5')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          SymbolGlyph($r('sys.symbol.chevron_down'))
            .fontSize(9)
            .fontColor(['#CFE0F5'])
            .margin({ left: 3 })
        }
        .constraintSize({ maxWidth: 150 })
        .padding({ left: 10, right: 8, top: 6, bottom: 6 })
        .borderRadius(13)
        .backgroundColor('#2F63A8')
        .margin({ right: 8 })
        .onClick(() => {
          this.showExamTerm = true;
        })
      }
      .width('100%')
      .padding({ left: 16, right: 14, top: 14, bottom: 12 })
      .backgroundColor('#1E4E8C')
      .bindSheet(this.showExamTerm, this.termSheet(false), {
        height: SheetSize.FIT_CONTENT,
        dragBar: true,
        showClose: false,
        backgroundColor: '#FFFFFF',
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
        .padding({ left: 14, right: 14, top: 8, bottom: 120 })
      }
    }
    .width('100%')
    .height('100%')
    .bindSheet(this.showExamDetail, this.examDetailSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: false,
      backgroundColor: '#FFFFFF',
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
          .fontColor('#26313F')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.examDate(it.time))
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1E4E8C')
      }
      .width('100%')

      Row() {
        SymbolGlyph($r('sys.symbol.clock'))
          .fontSize(10)
          .fontColor(['#9AA4B2'])
          .margin({ right: 3 })
        Text(this.examTime(it.time))
          .fontSize(11)
          .fontColor('#6B7686')
        Blank()
        Text(it.place)
          .fontSize(11)
          .fontColor('#6B7686')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .margin({ top: 6 })

      Text(it.examName)
        .fontSize(9)
        .fontColor('#B0B8C4')
        .margin({ top: 4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .backgroundColor('#FFFFFF')
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
        .fontColor(this.tab === idx ? ['#1E4E8C'] : ['#8A94A6'])
      Text(label)
        .fontSize(10)
        .fontWeight(this.tab === idx ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.tab === idx ? '#1E4E8C' : '#8A94A6')
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
            .fontColor('#FFFFFF')
          Text(this.timetableSubtitle())
            .fontSize(11)
            .fontColor('#BFD2EA')
            .margin({ top: 2 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Row() {
          Text(this.semester === '' ? '选择学期' : this.semester)
            .fontSize(10)
            .fontColor('#CFE0F5')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          SymbolGlyph($r('sys.symbol.chevron_down'))
            .fontSize(9)
            .fontColor(['#CFE0F5'])
            .margin({ left: 3 })
        }
        .constraintSize({ maxWidth: 150 })
        .padding({ left: 10, right: 8, top: 6, bottom: 6 })
        .borderRadius(13)
        .backgroundColor('#2F63A8')
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
            .fontColor(['#CFE0F5'])
        }
        .width(26)
        .height(26)
        .justifyContent(FlexAlign.Center)
        .borderRadius(13)
        .backgroundColor('#2F63A8')
        .onClick(() => {
          this.step(-1);
        })

        Column() {
          Text(`第 ${this.week} 周`)
            .fontSize(12)
            .fontColor('#FFFFFF')
          Text(this.weekRange())
            .fontSize(9)
            .fontColor('#9FBEE3')
            .margin({ top: 1 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)

        Row() {
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(13)
            .fontColor(['#CFE0F5'])
        }
        .width(26)
        .height(26)
        .justifyContent(FlexAlign.Center)
        .borderRadius(13)
        .backgroundColor('#2F63A8')
        .onClick(() => {
          this.step(1);
        })

        Row() {
          SymbolGlyph($r('sys.symbol.calendar'))
            .fontSize(10)
            .fontColor(['#CFE0F5'])
            .margin({ right: 3 })
          Text(this.semesterKey === this.currentSemesterKey() ? '本周' : '第 1 周')
            .fontSize(10)
            .fontColor('#CFE0F5')
        }
        .padding({ left: 8, right: 9, top: 4, bottom: 4 })
        .borderRadius(12)
        .backgroundColor('#2F63A8')
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
    .backgroundColor('#1E4E8C')
    .bindSheet(this.showSemester, this.semesterSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: false,
      backgroundColor: '#FFFFFF',
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
        .fontColor('#16233A')
        .margin({ bottom: 6 })

      List() {
        ForEach(this.semesters, (s: SemesterRef) => {
          ListItem() {
            Row() {
              Column() {
                Text(s.label)
                  .fontSize(14)
                  .fontWeight(s.key === this.semesterKey ? FontWeight.Bold : FontWeight.Normal)
                  .fontColor(s.key === this.semesterKey ? '#1E4E8C' : '#3A4657')
                Text(`${s.courseCount} 门课 · ${this.semesterTag(s)}`)
                  .fontSize(10)
                  .fontColor('#8A94A6')
                  .margin({ top: 2 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              if (s.key === this.semesterKey) {
                Text('当前')
                  .fontSize(10)
                  .fontColor('#FFFFFF')
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                  .borderRadius(8)
                  .backgroundColor('#1E4E8C')
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

      Divider().color('#EEF1F5').margin({ top: 2, bottom: 2 })

      Row() {
        Text('清空本地缓存数据')
          .fontSize(13)
          .fontColor('#B4543A')
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
          .fontColor('#FFFFFF')
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(9)
          .backgroundColor(this.nowColor())
        Blank()
        Text(this.updatedAt === '' ? '' : `数据 ${this.updatedAt}`)
          .fontSize(10)
          .fontColor('#9AA4B2')
      }
      .width('100%')

      Text(this.nowTitle())
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor('#16233A')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 8 })

      Text(this.nowSub())
        .fontSize(11)
        .fontColor('#6B7686')
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
          .fontColor('#9AA4B2')
      }
      .width('100%')
      .margin({ top: 8 })
    }
    .width('100%')
    .padding(14)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor('#FFFFFF')
    .borderRadius(12)
    .margin({ left: 12, right: 12, top: 10 })
  }

  /** 三个页签共用的空态：图标卡片 + 标题 + 说明 + 同步按钮 + 隐私说明 */
  @Builder
  pageEmpty(icon: Resource, title: string, hint: string) {
    Column() {
      Column() {
        SymbolGlyph(icon)
          .fontSize(40)
          .fontColor(['#C5D3E6'])
      }
      .width(76)
      .height(76)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .borderRadius(20)
      .backgroundColor('#EAF0F8')

      Text(title)
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor('#26313F')
        .margin({ top: 18 })

      Text(hint)
        .fontSize(11)
        .fontColor('#8A94A6')
        .textAlign(TextAlign.Center)
        .margin({ top: 8 })

      Row() {
        Text('从教务系统同步')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
      }
      .padding({ left: 26, right: 26, top: 11, bottom: 11 })
      .borderRadius(22)
      .backgroundColor('#1E4E8C')
      .margin({ top: 22 })
      .onClick(() => {
        router.pushUrl({ url: 'pages/SyncPage' });
      })

      Text('数据只存在本机，不经过任何服务器')
        .fontSize(9)
        .fontColor('#B0B8C4')
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
            .fontColor('#8A94A6')
          Text(p.start)
            .fontSize(8)
            .fontColor('#B7BFCC')
            .margin({ top: 1 })
        }
        .height(this.rowH)
        .width(this.timeW)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }, (p: Period) => `time_${p.index}`)
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
              .fontColor(this.today() === w.index ? '#1E4E8C' : '#5A6472')
          }
          .width(this.colW)
          .height(this.headH)
          .justifyContent(FlexAlign.Center)
          .backgroundColor(this.today() === w.index ? '#E3EDF9' : '#FFFFFF')
        }, (w: Weekday) => `head_${w.index}`)
      }

      Row() {
        ForEach(WEEKDAYS, (w: Weekday) => {
          this.dayColumn(w.index)
        }, (w: Weekday) => `col_${w.index}`)
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
              .backgroundColor(day >= 6 ? '#FAFBFD' : '#FFFFFF')
              .borderRadius(5)
          }
        }
        .width('100%')
        .height(s.span * this.rowH)
        .padding(1)
      }, (s: Slot) => `${this.week}_${day}_${s.period}_${s.course === null ? 'x' : s.course.id}`)
    }
    .width(this.colW)
  }

  @Builder
  courseCard(c: Course) {
    Column() {
      Text(c.name)
        .fontSize(this.nameFont())
        .lineHeight(this.nameFont() * 1.3)
        .fontColor(c.practice ? '#1D6B3F' : '#17427A')
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(c.location)
        .fontSize(this.locFont())
        .fontColor(c.practice ? '#2F7D52' : '#5B84B8')
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
    .backgroundColor(c.practice ? '#DDF3E4' : '#DCEAFA')
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
        .fontColor('#3A4657')
      Blank()
      Text('◇ 讲课   ◆ 实践/实验')
        .fontSize(9)
        .fontColor('#8A94A6')
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
          .fontColor('#3A4657')
          .layoutWeight(1)
        Text(c.weeks)
          .fontSize(10)
          .fontColor('#1E4E8C')
      }
      .width('100%')
      Row() {
        Text(c.teacher)
          .fontSize(10)
          .fontColor('#8A94A6')
          .layoutWeight(1)
        Text(c.note)
          .fontSize(9)
          .fontColor('#B0803A')
      }
      .width('100%')
      .margin({ top: 2 })
    }
    .width('100%')
    .padding(10)
    .margin({ bottom: 8 })
    .backgroundColor('#FFFFFF')
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
          .fontColor('#16233A')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(15)
          .fontColor(['#8A94A6'])
          .margin({ left: 8 })
          .onClick(() => {
            this.sheetShow = false;
          })
      }
      .width('100%')

      Text(this.selWeekHint())
        .fontSize(11)
        .fontColor(c.practice ? '#1D6B3F' : '#1E4E8C')
        .margin({ top: 6 })

      Divider().color('#EEF1F5').margin({ top: 12, bottom: 12 })

      Row() {
        Text('时间').fontSize(12).fontColor('#8A94A6').width(52)
        Text(`${weekdayLabel(c.weekday)} ${c.start}-${c.end} 节`)
          .fontSize(13).fontColor('#3A4657').layoutWeight(1)
      }
      .width('100%')

      Row() {
        Text('作息').fontSize(12).fontColor('#8A94A6').width(52)
        Text(timeRange(c.start, c.end)).fontSize(13).fontColor('#3A4657').layoutWeight(1)
      }
      .width('100%')
      .margin({ top: 10 })

      Row() {
        Text('地点').fontSize(12).fontColor('#8A94A6').width(52)
        Text(c.location).fontSize(13).fontColor('#3A4657').layoutWeight(1)
      }
      .width('100%')
      .margin({ top: 10 })

      Row() {
        Text('教师').fontSize(12).fontColor('#8A94A6').width(52)
        Text(c.teacher).fontSize(13).fontColor('#3A4657').layoutWeight(1)
      }
      .width('100%')
      .margin({ top: 10 })

      Row() {
        Text('周次').fontSize(12).fontColor('#8A94A6').width(52)
        Text(weeksLabel(c.weeks)).fontSize(13).fontColor('#3A4657').layoutWeight(1)
      }
      .width('100%')
      .margin({ top: 10 })

      if (c.note !== '') {
        Row() {
          Text('备注').fontSize(12).fontColor('#8A94A6').width(52)
          Text(c.note).fontSize(12).fontColor('#B0803A').layoutWeight(1)
        }
        .width('100%')
        .margin({ top: 10 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
