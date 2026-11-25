/**
 * 课表服务卡片（2*4 ArkTS 卡片，两段式）
 * 上：正在上课 / 下一节课；下：下一场考试
 * 数据由 EntryFormAbility 通过 formProvider.updateForm 推入，这里用 @LocalStorageProp 接收
 */

// 卡片颜色写死，不依赖 app.color 资源
const CARD_BG: string = '#FFFFFF';
const TAG_BG: string = '#EAF0F8';
const TAG_TEXT: string = '#1E4E8C';
const TEXT_PRIMARY: string = '#26313F';
const TEXT_SECONDARY: string = '#3A4657';
const TEXT_HINT: string = '#8A94A6';
const DIVIDER_COLOR: string = '#EEF1F5';
const EXAM_CHIP_BG: string = '#F1F5FA';
const FULL: string = '100%';

@Entry
@Component
struct TimetableCard {
  @LocalStorageProp('statusLabel') statusLabel: string = '下一节课';
  @LocalStorageProp('hasCourse') hasCourse: string = '0';
  @LocalStorageProp('courseName') courseName: string = '';
  @LocalStorageProp('coursePlace') coursePlace: string = '';
  @LocalStorageProp('courseWhen') courseWhen: string = '';
  @LocalStorageProp('courseTime') courseTime: string = '';
  @LocalStorageProp('courseRemain') courseRemain: string = '';
  @LocalStorageProp('hasExam') hasExam: string = '0';
  @LocalStorageProp('examName') examName: string = '';
  @LocalStorageProp('examDate') examDate: string = '';
  @LocalStorageProp('examSlot') examSlot: string = '';
  @LocalStorageProp('examPlace') examPlace: string = '';
  @LocalStorageProp('examRemain') examRemain: string = '';

  build() {
    Column() {
      // ------------------------------------------------ 第一段：正在上课 / 下一节课
      Column() {
        Row() {
          Text(this.statusLabel)
            .fontSize(9)
            .fontColor(TAG_TEXT)
            .padding({ left: 5, right: 5, top: 1, bottom: 1 })
            .borderRadius(4)
            .backgroundColor(TAG_BG)
          Blank()
          Text(this.courseWhen)
            .fontSize(9)
            .fontColor(TEXT_HINT)
        }
        .width(FULL)

        if (this.hasCourse === '1') {
          Text(this.courseName)
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(TEXT_PRIMARY)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 6 })
            .width(FULL)

          Row() {
            Text(this.courseTime)
              .fontSize(11)
              .fontWeight(FontWeight.Medium)
              .fontColor(TEXT_SECONDARY)
            Text(this.coursePlace)
              .fontSize(9)
              .fontColor(TEXT_HINT)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
              .textAlign(TextAlign.End)
              .margin({ left: 4 })
          }
          .width(FULL)
          .margin({ top: 4 })


        } else {
          Column() {
            Text('点此同步课表')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(TAG_TEXT)
            Text('打开应用同步一次即可')
              .fontSize(9)
              .fontColor(TEXT_HINT)
              .margin({ top: 3 })
          }
          .width(FULL)
          .alignItems(HorizontalAlign.Start)
          .margin({ top: 10 })
        }
      }
      .width(FULL)
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Divider()
        .color(DIVIDER_COLOR)
        .margin({ top: 10, bottom: 10 })

      // ------------------------------------------------ 第二段：下一场考试（与上一段同构）
      Column() {
        Row() {
          Text('下一场考试')
            .fontSize(9)
            .fontColor(TAG_TEXT)
            .padding({ left: 5, right: 5, top: 1, bottom: 1 })
            .borderRadius(4)
            .backgroundColor(TAG_BG)
          Blank()
          Text(this.hasExam === '1' ? this.examRemain : '')
            .fontSize(9)
            .fontColor(TEXT_HINT)
        }
        .width(FULL)

        if (this.hasExam === '1') {
          Text(this.examName)
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(TEXT_PRIMARY)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 6 })
            .width(FULL)

          Row() {
            Text(this.examDate + '  ' + this.examSlot)
              .fontSize(11)
              .fontWeight(FontWeight.Medium)
              .fontColor(TEXT_SECONDARY)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.examPlace)
              .fontSize(9)
              .fontColor(TEXT_HINT)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
              .textAlign(TextAlign.End)
              .margin({ left: 4 })
          }
          .width(FULL)
          .margin({ top: 4 })
        } else {
          Column() {
            Text('暂无考试安排')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(TEXT_SECONDARY)
            Text('教务排考后同步一次即可')
              .fontSize(9)
              .fontColor(TEXT_HINT)
              .margin({ top: 3 })
          }
          .width(FULL)
          .alignItems(HorizontalAlign.Start)
          .margin({ top: 8 })
        }
      }
      .width(FULL)
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width(FULL)
    .height(FULL)
    .padding(14)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(CARD_BG)
    .borderRadius(18)
    .onClick(() => {
      // 点整张卡片回到 App（EntryAbility 为本模块主入口）
      postCardAction(this, {
        action: 'router',
        abilityName: 'EntryAbility',
        params: {
          from: 'card'
        }
      });
    })
  }
}