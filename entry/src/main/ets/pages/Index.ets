import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';

const MIC: Permissions[] = ['ohos.permission.MICROPHONE'];

@Entry
@Component
struct Index {
  @State micState: string = '';

  private requestMic(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    abilityAccessCtrl.createAtManager().requestPermissionsFromUser(ctx, MIC).then((res) => {
      const granted: boolean = res.authResults.length > 0 && res.authResults[0] === 0;
      this.micState = granted ? '麥克風已授權 ✓' : '麥克風未授權，長按空白鍵語音輸入將不可用';
    }).catch(() => {
      this.micState = '授權請求失敗';
    });
  }

  build() {
    Column({ space: 16 }) {
      Text('hMixedKeyboard')
        .fontSize(26)
        .fontWeight(FontWeight.Bold)
      Text('粵英混輸輸入法')
        .fontSize(15)
        .fontColor('#666666')
      Text('語音輸入：在鍵盤上按住空白鍵約半秒開始錄音，放開後識別文字自動輸入。')
        .fontSize(14)
        .textAlign(TextAlign.Center)
      Button('授權麥克風')
        .onClick(() => {
          this.requestMic();
        })
      if (this.micState.length > 0) {
        Text(this.micState)
          .fontSize(14)
          .fontColor(this.micState.indexOf('✓') >= 0 ? '#2E7D32' : '#B3261E')
      }
    }
    .height('100%')
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding(24)
  }
}
