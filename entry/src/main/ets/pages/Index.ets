@Entry
@Component
struct Index {
  build() {
    Column({ space: 16 }) {
      Text('hMixedKeyboard')
        .fontSize(26)
        .fontWeight(FontWeight.Bold)
      Text('粵英混輸輸入法')
        .fontSize(15)
        .fontColor('#666666')
      Text('請在 設定 > 系統和更新 > 語言和輸入法 中啟用 hMixedKeyboard。')
        .fontSize(14)
        .textAlign(TextAlign.Center)
    }
    .height('100%')
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding(24)
  }
}
