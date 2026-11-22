import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { TimetableRepo, SemesterRef, SemesterIndex, SyncedSemester } from '../model/TimetableRepo';
import { JwSync, SyncedSemesterData, GradeItem, ExamItem } from '../model/JwSync';

/** 统一身份认证 → 教务系统（办事大厅点「教务系统」跳的就是这个） */
const SSO_URL: string = 'https://uaaap.swu.edu.cn/cas/login?service=https%3A%2F%2Fjw.swu.edu.cn%2Fsso%2Fzllogin';
const JW_KBCX: string = 'https://jw.swu.edu.cn/jwglxt/kbcx/xskbcx_cxXskbcxIndex.html?gnmkdm=N253508&layout=default';

@Component
export struct SyncPage {
  /** 同步成功后通知宿主刷新数据 */
  onSynced: () => void = () => {};
  /** 清空本地数据后通知宿主回到空态 */
  onCleared: () => void = () => {};
  /** 关闭登录浮层 */
  onClose: () => void = () => {};

  @State status: string = '登录完成后，点下方按钮同步';
  @State currentUrl: string = '';
  @State debugInfo: string = '';
  @State busy: boolean = false;
  @State done: boolean = false;

  private controller: webview.WebviewController = new webview.WebviewController();
  private timerId: number = -1;
  private gradeCount: number = 0;
  private examCount: number = 0;
  private firstErr: string = '';
  private started: boolean = false;
  private clearing: boolean = false;
  /** 每次清空自增；进行中的同步发现代次变了就丢弃结果 */
  private syncGen: number = 0;
  /** 上一次失败的 cookie 指纹：同一个会话失败后不再自动重试，避免每 1.5 秒刷一次 */
  private failedCookie: string = '';

  aboutToAppear(): void {
    this.persistCookies();
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
    if (this.started || this.done || this.clearing) {
      return;
    }
    try {
      const raw: string = this.controller.getUrl();
      const url: string = raw.length > 70 ? raw.slice(0, 70) + '…' : raw;
      // 只有真的变了才赋值，避免每 1.5 秒触发一次重绘（登录时页面会闪）
      if (url !== '' && url !== this.currentUrl) {
        this.currentUrl = url;
      }
    } catch (err) {
      // 控制器未就绪
    }

    const cookie: string = JwSync.cookie();
    const ok: boolean = JwSync.isLoggedIn(cookie);
    if (ok && cookie === this.failedCookie) {
      // 这个会话已经失败过，等用户重新登录（cookie 变了）再说
      return;
    }
    if (ok) {
      this.started = true;
      this.status = '已登录，正在抓取课表、成绩和考试…';
      this.persistCookies();
      this.runSync(cookie);
      return;
    }

    let next: string = '';
    if (this.currentUrl.indexOf('uaaap.swu.edu.cn') >= 0 || this.currentUrl.indexOf('idm.swu.edu.cn') >= 0) {
      next = '请在下方完成登录，登录后会自动抓取';
    } else if (this.currentUrl.indexOf('jw.swu.edu.cn') >= 0) {
      next = '正在进入教务系统…';
    }
    if (next !== '' && next !== this.status) {
      this.status = next;
    }
  }

  /** 用户点"开始同步"才抓取，不再轮询 */
  private startSync(): void {
    const cookie: string = JwSync.cookie();
    if (!JwSync.isLoggedIn(cookie)) {
      this.status = '还没检测到登录状态，请先完成登录再点';
      return;
    }
    this.failedCookie = '';
    this.started = true;
    this.busy = true;
    this.status = '正在抓取课表、成绩和考试…';
    this.runSync(cookie);
  }

  private async clearAll(): Promise<void> {
    const ctx: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (ctx === undefined || ctx === null) {
      return;
    }
    // 先挡住自动同步，否则清完下一秒又被 tick 抓回来
    this.clearing = true;
    this.started = true;
    this.syncGen++;

    await TimetableRepo.clear(ctx);

    // 一并退出登录，避免下次进页面又自动抓取
    try {
      webview.WebCookieManager.clearAllCookiesSync(false);
    } catch (err) {
      // 忽略
    }

    this.busy = false;
    this.done = false;
    this.failedCookie = '';
    this.status = '已清空本地数据，需要重新登录';
    this.currentUrl = '';
    this.debugInfo = 'cookie: 已清除';

    try {
      this.controller.loadUrl(SSO_URL);
    } catch (err) {
      // 忽略
    }

    this.onCleared();
    setTimeout(() => {
      this.clearing = false;
      this.started = false;
    }, 1500);
  }

  private async runSync(cookie: string): Promise<void> {
    this.busy = true;
    const gen: number = this.syncGen;
    try {
      const all: SyncedSemesterData[] = await JwSync.fetchAll(cookie);
      if (all.length === 0) {
        this.busy = false;
        this.started = false;
        this.failedCookie = cookie;
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
          if (this.firstErr === '') {
            this.firstErr = '成绩：' + (err as Error).message.slice(0, 40);
          }
        }
        try {
          const e2: ExamItem[] = await JwSync.fetchExams(cookie, combos[i][0], combos[i][1]);
          for (let k: number = 0; k < e2.length; k++) {
            exams.push(e2[k]);
          }
        } catch (err) {
          if (this.firstErr === '') {
            this.firstErr = '考试：' + (err as Error).message.slice(0, 40);
          }
        }
      }
      exams.sort((a: ExamItem, b: ExamItem) => a.time.localeCompare(b.time));
      this.gradeCount = grades.length;
      this.examCount = exams.length;

      if (gen !== this.syncGen) {
        // 抓取期间用户点了"清空数据"，丢弃这批结果
        this.busy = false;
        this.started = false;
        return;
      }
      await this.save(all, grades, exams);
    } catch (e) {
      this.busy = false;
      this.started = false;
      // 记下这个会话，tick 不会再用它自动重试（否则每 1.5 秒刷一次）
      this.failedCookie = cookie;
      const msg: string = (e as Error).message;
      this.status = msg === 'EXPIRED' ? '登录已过期，请重新登录' : `抓取失败：${msg.slice(0, 30)}`;
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
    const summary: string =
      `课表 ${items.length} 学期 · 成绩 ${this.gradeCount} 门 · 考试 ${this.examCount} 场`;
    this.status = ok
      ? (this.gradeCount === 0 && this.firstErr !== ''
        ? `已同步课表，但${this.firstErr}`
        : `同步完成：${summary}`)
      : '写入本地失败';
    if (ok) {
      setTimeout(() => {
        this.onSynced();
      }, 900);
    }
  }

  build() {
    Column() {
      Row() {
        Text('登录教务系统')
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .layoutWeight(1)

        Row() {
          Text('关闭')
            .fontSize(12)
            .fontColor('#1E4E8C')
        }
        .height(28)
        .padding({ left: 12, right: 12 })
        .borderRadius(14)
        .backgroundColor('#E6EEF9')
        .onClick(() => {
          this.onClose();
        })
      }
      .width('100%')
      .height(56)
      .padding({ left: 16, right: 14 })
      .backgroundColor('#1E4E8C')

      if (this.done) {
        Column() {
          SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
            .fontSize(46)
            .fontColor(['#19A461'])
          Text('同步完成')
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor('#26313F')
            .margin({ top: 14 })
          Text(this.status)
            .fontSize(12)
            .fontColor('#6B7686')
            .margin({ top: 8 })
            .textAlign(TextAlign.Center)

          Row() {
            Text('重新同步')
              .fontSize(14)
              .fontColor('#1E4E8C')
          }
          .padding({ left: 22, right: 22, top: 9, bottom: 9 })
          .borderRadius(18)
          .backgroundColor('#E6EEF9')
          .margin({ top: 20 })
          .onClick(() => {
            this.done = false;
            this.started = false;
            this.status = '正在打开统一身份认证…';
            try {
              this.controller.loadUrl(SSO_URL);
            } catch (err) {
              // 忽略
            }
          })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor('#F2F4F7')
      } else {
        Web({ src: SSO_URL, controller: this.controller })
          .javaScriptAccess(true)
          .domStorageAccess(true)
          .fileAccess(false)
          .mixedMode(MixedMode.All)
          .backgroundColor(Color.White)
          .width('100%')
          .layoutWeight(1)

        Column() {
          Row() {
            if (this.busy) {
              LoadingProgress().width(12).height(12).color('#1E4E8C').margin({ right: 6 })
            }
            Text(this.status)
              .fontSize(11)
              .fontColor('#6B7686')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .width('100%')
          .height(22)

          Row() {
            Text(this.busy ? '正在同步…' : '开始同步')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF')
          }
          .width('100%')
          .height(44)
          .justifyContent(FlexAlign.Center)
          .borderRadius(22)
          .backgroundColor(this.busy ? '#9BB4D8' : '#1E4E8C')
          .margin({ top: 6 })
          .onClick(() => {
            if (!this.busy) {
              this.startSync();
            }
          })
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 8, bottom: 14 })
        .backgroundColor('#FFFFFF')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F2F4F7')
  }
}
