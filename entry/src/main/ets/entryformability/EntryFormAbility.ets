/**
 * 课表卡片（服务卡片）的 FormExtensionAbility
 * onAddForm 先返回占位数据，再异步把首选项里的课表推给卡片；
 * App 内同步完成后调用 EntryFormAbility.push(context) 刷新所有已添加的卡片
 */

import { common, Want } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FormExtensionAbility, formBindingData, formInfo, formProvider } from '@kit.FormKit';
import { FormData } from '../widget/common/FormData';

const DOMAIN: number = 0x0E00;
const TAG: string = 'TimetableCard';
/** 与 TimetableRepo 同一份首选项 */
const STORE_NAME: string = 'timetable_store';
/** 自己维护的卡片 formId 清单（字符串数组的 JSON） */
const KEY_FORM_IDS: string = 'widget_form_ids';

export default class EntryFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    const formId: string = EntryFormAbility.formIdOf(want);
    hilog.info(DOMAIN, TAG, 'onAddForm formId=%{public}s', formId);
    // 先记下 formId 再把真实数据推过去，同步读首选项这里来不及
    this.refreshForm(formId);
    return formBindingData.createFormBindingData(FormData.emptyJson());
  }

  /** 系统到点刷新（form_config 的 updateDuration）时回调 */
  onUpdateForm(formId: string): void {
    this.refreshForm(formId);
  }

  /** 卡片上的 FormLink / postCardAction 事件 */
  onFormEvent(formId: string, message: string): void {
    hilog.info(DOMAIN, TAG, 'onFormEvent %{public}s %{public}s', formId, message);
    this.refreshForm(formId);
  }

  /** 卡片被删除：从清单里摘掉，免得 updateForm 一直报错 */
  onRemoveForm(formId: string): void {
    EntryFormAbility.forgetForm(this.context, formId);
  }

  /**
   * App 内同步完成、或页面回到前台后调用：
   * 把最新数据推给所有已添加的卡片；一张卡片都没有时安全返回
   */
  static async push(context: common.Context): Promise<void> {
    const ids: string[] = await EntryFormAbility.loadFormIds(context);
    if (ids.length === 0) {
      return;
    }
    const data: string = await FormData.build(context);
    const binding: formBindingData.FormBindingData = formBindingData.createFormBindingData(data);
    const alive: string[] = [];
    for (let i: number = 0; i < ids.length; i++) {
      try {
        await formProvider.updateForm(ids[i], binding);
        alive.push(ids[i]);
      } catch (err) {
        // 卡片已被移除，下次不再推
        hilog.warn(DOMAIN, TAG, 'form %{public}s not found', ids[i]);
      }
    }
    if (alive.length !== ids.length) {
      await EntryFormAbility.saveFormIds(context, alive);
    }
  }

  /** 记 formId + 推这张卡片 */
  private async refreshForm(formId: string): Promise<void> {
    if (formId === '') {
      return;
    }
    const ctx: common.Context = this.context;
    await EntryFormAbility.rememberForm(ctx, formId);
    try {
      const data: string = await FormData.build(ctx);
      await formProvider.updateForm(formId, formBindingData.createFormBindingData(data));
    } catch (err) {
      const e: Error = err as Error;
      hilog.error(DOMAIN, TAG, 'updateForm failed: %{public}s', e.message);
    }
  }

  // -------------------------------------------------------------- formId 清单

  /** formId 由系统在 want.parameters 的 IDENTITY_KEY 里给出 */
  private static formIdOf(want: Want): string {
    const params: Record<string, Object> | undefined = want.parameters;
    if (params === undefined || params === null) {
      return '';
    }
    const raw: Object | undefined = params[formInfo.FormParam.IDENTITY_KEY];
    if (raw === undefined || raw === null) {
      return '';
    }
    return raw as string;
  }

  private static async loadFormIds(ctx: common.Context): Promise<string[]> {
    const store: preferences.Preferences | null = await EntryFormAbility.openStore(ctx);
    if (store === null) {
      return [];
    }
    try {
      const text: string = store.getSync(KEY_FORM_IDS, '') as string;
      if (text === '') {
        return [];
      }
      const ids: string[] = JSON.parse(text) as string[];
      if (ids === null || ids === undefined) {
        return [];
      }
      return ids;
    } catch (err) {
      return [];
    }
  }

  private static async saveFormIds(ctx: common.Context, ids: string[]): Promise<void> {
    const store: preferences.Preferences | null = await EntryFormAbility.openStore(ctx);
    if (store === null) {
      return;
    }
    try {
      store.putSync(KEY_FORM_IDS, JSON.stringify(ids));
      await store.flush();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'save formIds failed');
    }
  }

  private static async rememberForm(ctx: common.Context, formId: string): Promise<void> {
    const ids: string[] = await EntryFormAbility.loadFormIds(ctx);
    if (ids.indexOf(formId) >= 0) {
      return;
    }
    ids.push(formId);
    await EntryFormAbility.saveFormIds(ctx, ids);
  }

  private static async forgetForm(ctx: common.Context, formId: string): Promise<void> {
    const ids: string[] = await EntryFormAbility.loadFormIds(ctx);
    const idx: number = ids.indexOf(formId);
    if (idx < 0) {
      return;
    }
    ids.splice(idx, 1);
    await EntryFormAbility.saveFormIds(ctx, ids);
  }

  private static async openStore(ctx: common.Context): Promise<preferences.Preferences | null> {
    try {
      return await preferences.getPreferences(ctx, STORE_NAME);
    } catch (err) {
      return null;
    }
  }
}
