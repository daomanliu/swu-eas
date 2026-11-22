import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { TimetableRepo, SemesterRef, SemesterIndex, SyncedSemester } from '../model/TimetableRepo';
import { JwSync, SyncedSemesterData, GradeItem, ExamItem } from '../model/JwSync';

/** 统一身份认证 → 教务系统（办事大厅点「教务系统」跳的就是这个） */
const SSO_URL: string = 'https://uaaap.swu.edu.cn/cas/login?service=https%3A%2F%2Fjw.swu.edu.cn%2Fsso%2Fzllogin';
const JW_KBCX: string = 'https://jw.swu.edu.cn/jwglxt/kbcx/xskbcx_cxXskbcxIndex.html?gnmkdm=N253508&layout=default';

@Entry
@Component
struct SyncPage {
  @State status: string = '正在打开统一身份认证…';
  @State currentUrl: string = '';
  @State debugInfo: string = '';
  @State busy: boolean = false;
  @State done: boolean = false;

  private controller: webview.WebviewController = new webview.WebviewController();
  private timerId: number = -1;
  private started: boolean = false;

  aboutToAppear(): void {
    this.persistCookies();
    this.timerId = setInterval(() => {
      this.tick();
    }, 1500);
  }

  aboutToDisappear(): void {
    if (this.timerId !== -1) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  private persistCookies(): void {
    try {
      webview.WebCookieManager.saveCookieSync();
    } catch (err) {
      // 忽略
    }
  }

  /** 只做一件事：等教务域名的 cookie 出现，然后走 HTTP 抓取 */
  private tick(): void {
    if (this.started || this.done) {
      return;
    }
    try {
      const url: string = this.controller.getUrl();
      if (url !== '') {
        this.currentUrl = url.length > 70 ? url.slice(0, 70) + '…' : url;
      }
    } catch (err) {
      // 控制器未就绪
    }

    const cookie: string = JwSync.cookie();
    const ok: boolean = JwSync.isLoggedIn(cookie);
    this.debugInfo = cookie === ''
      ? 'cookie: 无'
      : `cookie: ${cookie.length} 字符${ok ? ' · 有 JSESSIONID' : ' · 无 JSESSIONID'}`;
    if (ok) {
      this.started = true;
      this.status = '已登录，正在抓取各学期课表…';
      this.persistCookies();
      this.runSync(cookie);
      return;
    }

    if (this.currentUrl.indexOf('uaaap.swu.edu.cn') >= 0 || this.currentUrl.indexOf('idm.swu.edu.cn') >= 0) {
      this.status = '请在下方完成登录，登录后会自动抓取';
    } else if (this.currentUrl.indexOf('jw.swu.edu.cn') >= 0) {
      this.status = '正在进入教务系统…';
    }
  }

  private async runSync(cookie: string): Promise<void> {
    this.busy = true;
    try {
      const all: SyncedSemesterData[] = await JwSync.fetchAll(cookie);
      if (all.length === 0) {
        this.busy = false;
        this.started = false;
        this.status = '没有拿到课表，请确认已登录教务系统';
        return;
      }

      // 顺带把成绩和考试也拉下来
      this.status = '正在抓取课表、成绩和考试…';
      const grades: GradeItem[] = [];
      const exams: ExamItem[] = [];
      const year: number = new Date().getFullYear();
      const combos: number[][] = [[year, 3], [year, 12], [year - 1, 3], [year - 1, 12]];
      for (let i: number = 0; i < combos.length; i++) {
        try {
          const g: GradeItem[] = await JwSync.fetchGrades(cookie, combos[i][0], combos[i][1]);
          for (let k: number = 0; k < g.length; k++) {
            grades.push(g[k]);
          }
        } catch (err) {
          // 单个学期失败不影响整体
        }
        try {
          const e2: ExamItem[] = await JwSync.fetchExams(cookie, combos[i][0], combos[i][1]);
          for (let k: number = 0; k < e2.length; k++) {
            exams.push(e2[k]);
          }
        } catch (err) {
          // 同上
        }
      }
      exams.sort((a: ExamItem, b: ExamItem) => a.time.localeCompare(b.time));

      await this.save(all, grades, exams);
    } catch (e) {
      this.busy = false;
      this.started = false;
      const msg: string = (e as Error).message;
      this.status = msg === 'EXPIRED' ? '教务系统登录已过期，请重新登录' : `抓取失败：${msg.slice(0, 30)}`;
    }
  }

  private async save(all: SyncedSemesterData[], grades: GradeItem[], exams: ExamItem[]): Promise<void> {
    const ctx: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (ctx === undefined || ctx === null) {
      this.busy = false;
      this.status = '上下文不可用';
      return;
    }

    const oldIdx: SemesterIndex | null = await TimetableRepo.loadIndexCached(ctx);
    const payloads: SyncedSemester[] = [];
    const items: SemesterRef[] = [];
    for (let i: number = 0; i < all.length; i++) {
      const it: SyncedSemesterData = all[i];
      let start: string = '';
      if (oldIdx !== null) {
        const old: SemesterRef | undefined = oldIdx.items.find((x: SemesterRef) => x.key === it.key);
        if (old !== undefined) {
          start = old.start;
        }
      }
      payloads.push({ key: it.key, json: JSON.stringify(it.snapshot) });
      items.push({ key: it.key, label: it.label, start: start, courseCount: it.snapshot.courses.length });
    }

    items.sort((a: SemesterRef, b: SemesterRef) => {
      const ay: number = Number(a.key.split('_')[0]);
      const by: number = Number(b.key.split('_')[0]);
      if (ay !== by) {
        return by - ay;
      }
      return Number(b.key.split('_')[1]) - Number(a.key.split('_')[1]);
    });

    const now = new Date();
    const m: number = now.getMonth() + 1;
    const y: number = now.getFullYear();
    const curXn: number = (m >= 9) ? y : y - 1;
    const curXq: number = (m >= 9 || m <= 1) ? 3 : 12;
    const curKey: string = `${curXn}_${curXq}`;

    const index: SemesterIndex = {
      default: items.some((x: SemesterRef) => x.key === curKey) ? curKey : items[0].key,
      items: items
    };

    await TimetableRepo.saveExtras(ctx, JSON.stringify(grades), JSON.stringify(exams));
    const ok: boolean = await TimetableRepo.saveSynced(ctx, index, payloads);
    this.persistCookies();
    this.busy = false;
    this.done = ok;
    this.status = ok ? `同步完成：${items.length} 个学期` : '写入本地失败';
    if (ok) {
      setTimeout(() => {
        router.back();
      }, 900);
    }
  }

  build() {
    Column() {
      Row() {
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(14).fontColor(['#1E4E8C'])
          Text('返回').fontSize(14).fontColor('#1E4E8C').margin({ left: 2 })
        }
        .width(72)
        .onClick(() => {
          router.back();
        })

        Text('从教务系统同步')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#16233A')
          .layoutWeight(1)
          .textAlign(TextAlign.Center)

        Text('').width(72)
      }
      .width('100%')
      .height(52)
      .padding({ left: 12, right: 12 })
      .backgroundColor('#FFFFFF')

      Row() {
        if (this.busy) {
          LoadingProgress().width(14).height(14).color('#1E4E8C').margin({ right: 6 })
        }
        Text(this.status)
          .fontSize(11)
          .fontColor(this.done ? '#19A461' : '#6B7686')
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 8, bottom: 4 })
      .backgroundColor('#F7F9FC')

      Row() {
        Column() {
          Text(this.currentUrl)
            .fontSize(9)
            .fontColor('#A0A8B4')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(this.debugInfo)
            .fontSize(9)
            .fontColor('#C09050')
            .maxLines(1)
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Text('直接打开教务')
          .fontSize(10)
          .fontColor('#1E4E8C')
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(8)
          .backgroundColor('#E6EEF9')
          .margin({ left: 8 })
          .onClick(() => {
            try {
              this.controller.loadUrl(JW_KBCX);
            } catch (err) {
              this.status = '打开教务失败';
            }
          })
      }
      .width('100%')
      .padding({ left: 14, right: 14, bottom: 8 })
      .backgroundColor('#F7F9FC')

      Web({ src: SSO_URL, controller: this.controller })
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .fileAccess(false)
        .mixedMode(MixedMode.All)
        .width('100%')
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F2F4F7')
  }
}
