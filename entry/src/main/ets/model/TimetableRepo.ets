import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { TimetableSnapshot } from './TimetableData';

const STORE_NAME: string = 'timetable_store';
const KEY_JSON: string = 'timetable_json';
const KEY_CACHED_AT: string = 'timetable_cached_at';
const RAWFILE: string = 'timetable.json';
const KEY_INDEX: string = 'semesters_index';
const KEY_LAST_SYNC: string = 'last_sync_at';

/** App 内同步得到的一个学期数据 */
export interface SyncedSemester {
  key: string;
  json: string;
}

export interface LoadResult {
  snapshot: TimetableSnapshot | null;
  source: string;      // bundle | cache | none
  cachedAt: string;
}

/** semesters.json 里的一项 */
export interface SemesterRef {
  key: string;         // 如 2026_3
  label: string;
  start: string;       // 学期第一周周一，空表示未知
  courseCount: number;
}

export interface SemesterIndex {
  default: string;
  items: SemesterRef[];
}

/**
 * 课表数据读写：
 *  - 首次启动从 rawfile 读取（打包进 HAP 的数据）并落盘到 Preferences
 *  - 之后优先用本地缓存；rawfile 更新不会覆盖缓存，除非显式 save()
 *  - Preferences 不可用时自动降级为只读 rawfile
 */
export class TimetableRepo {
  static parse(text: string): TimetableSnapshot | null {
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

  static readRaw(ctx: common.UIAbilityContext, name: string): string {
    try {
      const bytes: Uint8Array = ctx.resourceManager.getRawFileContentSync(name);
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(bytes);
    } catch (err) {
      return '';
    }
  }

  static readBundle(ctx: common.UIAbilityContext): string {
    return TimetableRepo.readRaw(ctx, RAWFILE);
  }

  /** 读学期索引：优先 App 内同步产生的缓存，其次打包的 semesters.json */
  static async loadIndexCached(ctx: common.UIAbilityContext): Promise<SemesterIndex | null> {
    const store: preferences.Preferences | null = await TimetableRepo.openStore(ctx);
    if (store !== null) {
      try {
        const text: string = store.getSync(KEY_INDEX, '') as string;
        if (text !== '') {
          const idx: SemesterIndex = JSON.parse(text) as SemesterIndex;
          if (idx !== null && idx.items !== undefined && idx.items.length > 0) {
            return idx;
          }
        }
      } catch (err) {
        // 缓存损坏则回退
      }
    }
    return TimetableRepo.loadIndex(ctx);
  }

  /** App 内同步完成后落盘：索引 + 每个学期的课表 */
  static async saveSynced(
    ctx: common.UIAbilityContext,
    index: SemesterIndex,
    payloads: SyncedSemester[]
  ): Promise<boolean> {
    const store: preferences.Preferences | null = await TimetableRepo.openStore(ctx);
    if (store === null) {
      return false;
    }
    try {
      for (let i: number = 0; i < payloads.length; i++) {
        store.putSync(`tt_${payloads[i].key}`, payloads[i].json);
      }
      store.putSync(KEY_INDEX, JSON.stringify(index));
      store.putSync(KEY_LAST_SYNC, new Date().toISOString());
      await store.flush();
      return true;
    } catch (err) {
      return false;
    }
  }

  /** 读学期索引；没有索引（老版本数据）返回 null */
  static loadIndex(ctx: common.UIAbilityContext): SemesterIndex | null {
    const text: string = TimetableRepo.readRaw(ctx, 'semesters.json');
    if (text === '') {
      return null;
    }
    try {
      const idx: SemesterIndex = JSON.parse(text) as SemesterIndex;
      if (idx === null || idx.items === undefined || idx.items.length === 0) {
        return null;
      }
      return idx;
    } catch (err) {
      return null;
    }
  }

  /** 读某个学期；bundle 与缓存谁新用谁 */
  static async loadSemester(ctx: common.UIAbilityContext, key: string): Promise<LoadResult> {
    const bundled: string = TimetableRepo.readRaw(ctx, `timetable_${key}.json`);
    const bundleSnap: TimetableSnapshot | null = TimetableRepo.parse(bundled);

    const store: preferences.Preferences | null = await TimetableRepo.openStore(ctx);
    let cachedSnap: TimetableSnapshot | null = null;
    if (store !== null) {
      try {
        cachedSnap = TimetableRepo.parse(store.getSync(`tt_${key}`, '') as string);
      } catch (err) {
        cachedSnap = null;
      }
    }

    let useBundle: boolean = bundleSnap !== null;
    if (bundleSnap !== null && cachedSnap !== null) {
      useBundle = TimetableRepo.isNewer(bundleSnap.generatedAt, cachedSnap.generatedAt);
    }

    const snap: TimetableSnapshot | null = useBundle ? bundleSnap : cachedSnap;
    if (snap === null) {
      return { snapshot: null, source: 'none', cachedAt: '' };
    }

    if (useBundle && store !== null) {
      try {
        store.putSync(`tt_${key}`, bundled);
        await store.flush();
      } catch (err) {
        // 落盘失败不影响使用
      }
    }

    return { snapshot: snap, source: useBundle ? 'bundle' : 'cache', cachedAt: snap.generatedAt };
  }

  private static isNewer(a: string, b: string): boolean {
    const ta: number = new Date(a).getTime();
    const tb: number = new Date(b).getTime();
    if (isNaN(ta)) {
      return false;
    }
    if (isNaN(tb)) {
      return true;
    }
    return ta > tb;
  }

  private static async openStore(ctx: common.UIAbilityContext): Promise<preferences.Preferences | null> {
    try {
      return await preferences.getPreferences(ctx, STORE_NAME);
    } catch (err) {
      return null;
    }
  }

  static async load(ctx: common.UIAbilityContext): Promise<LoadResult> {
    const store: preferences.Preferences | null = await TimetableRepo.openStore(ctx);

    // 1) 优先读缓存
    if (store !== null) {
      try {
        const cached: string = store.getSync(KEY_JSON, '') as string;
        if (cached !== '') {
          const snap: TimetableSnapshot | null = TimetableRepo.parse(cached);
          if (snap !== null) {
            const at: string = store.getSync(KEY_CACHED_AT, '') as string;
            return { snapshot: snap, source: 'cache', cachedAt: at !== '' ? at : snap.generatedAt };
          }
        }
      } catch (err) {
        // 缓存损坏则继续走 rawfile
      }
    }

    // 2) 读打包数据
    const bundled: string = TimetableRepo.readBundle(ctx);
    const snap: TimetableSnapshot | null = TimetableRepo.parse(bundled);
    if (snap === null) {
      return { snapshot: null, source: 'none', cachedAt: '' };
    }

    // 3) 首次落盘
    if (store !== null) {
      try {
        store.putSync(KEY_JSON, bundled);
        store.putSync(KEY_CACHED_AT, snap.generatedAt);
        await store.flush();
      } catch (err) {
        // 落盘失败不影响本次使用
      }
    }

    return { snapshot: snap, source: 'bundle', cachedAt: snap.generatedAt };
  }

  /** 用新的课表 JSON 覆盖本地缓存（为将来 App 内直接同步预留） */
  static async save(ctx: common.UIAbilityContext, text: string): Promise<boolean> {
    const snap: TimetableSnapshot | null = TimetableRepo.parse(text);
    if (snap === null) {
      return false;
    }
    const store: preferences.Preferences | null = await TimetableRepo.openStore(ctx);
    if (store === null) {
      return false;
    }
    try {
      store.putSync(KEY_JSON, text);
      store.putSync(KEY_CACHED_AT, snap.generatedAt);
      await store.flush();
      return true;
    } catch (err) {
      return false;
    }
  }

  /** 最后一次真正同步的时间；空表示从没同步过（当前用的是打包数据） */
  static async lastSyncAt(ctx: common.UIAbilityContext): Promise<string> {
    const store: preferences.Preferences | null = await TimetableRepo.openStore(ctx);
    if (store === null) {
      return '';
    }
    try {
      return store.getSync(KEY_LAST_SYNC, '') as string;
    } catch (err) {
      return '';
    }
  }

  static async clear(ctx: common.UIAbilityContext): Promise<void> {
    const store: preferences.Preferences | null = await TimetableRepo.openStore(ctx);
    if (store === null) {
      return;
    }
    try {
      store.deleteSync(KEY_JSON);
      store.deleteSync(KEY_CACHED_AT);
      store.deleteSync(KEY_INDEX);
      store.deleteSync(KEY_LAST_SYNC);
      const all: Object = store.getAllSync();
      const keys: string[] = Object.keys(all);
      for (let i: number = 0; i < keys.length; i++) {
        if (keys[i].indexOf('tt_') === 0) {
          store.deleteSync(keys[i]);
        }
      }
      await store.flush();
    } catch (err) {
      // 清理失败可忽略
    }
  }
}
