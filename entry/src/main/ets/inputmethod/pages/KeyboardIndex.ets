import { Cand } from '../model/DictEngine';
import { mixedController } from '../model/MixedController';

const LETTER_ROW_1: string[] = ['q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p'];
const LETTER_ROW_2: string[] = ['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l'];
const LETTER_ROW_3: string[] = ['z', 'x', 'c', 'v', 'b', 'n', 'm'];
const NUM_ROW_1: string[] = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'];
const NUM_ROW_2: string[] = ['@', '#', '$', '_', '&', '-', '+', '(', ')'];
const NUM_ROW_3: string[] = ['*', '"', "'", ':', ';', '!', '?'];

const BG_PANEL: string = '#E4E7EC';
const BG_BAR: string = '#F7F8FA';
const BG_KEY: string = '#FFFFFF';
const BG_FUNC: string = '#C9CEDA';
const FG_TEXT: string = '#1A1C1E';

@Entry
@Component
struct KeyboardIndex {
  @State composition: string = '';
  @State candidates: Cand[] = [];
  @State predicting: boolean = false;
  @State numericMode: boolean = false;

  aboutToAppear(): void {
    mixedController.setUiListener((comp: string, cands: Cand[], predicting: boolean) => {
      this.composition = comp;
      this.candidates = cands;
      this.predicting = predicting;
    });
  }

  aboutToDisappear(): void {
    mixedController.setUiListener(undefined);
  }

  private barLabel(): string {
    if (this.predicting) {
      return '聯想';
    }
    return this.composition.length > 0 ? this.composition : 'hMixed';
  }

  @Builder
  CandidateBar() {
    Scroll() {
      Row({ space: 4 }) {
        Text(this.barLabel())
          .fontSize(14)
          .fontColor('#8A8F99')
          .backgroundColor('#E2E5EB')
          .borderRadius(6)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .margin({ right: 4 })
        ForEach(this.candidates, (cand: Cand, index: number) => {
          Text(cand.text)
            .fontSize(22)
            .fontColor(cand.simplified ? '#5B6472' : FG_TEXT)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .borderRadius(6)
            .backgroundColor(index === 0 && !this.predicting ? '#DCE4F7' : Color.Transparent)
            .onClick(() => {
              mixedController.chooseCandidate(index);
            })
        }, (cand: Cand, index: number) => `${index}_${cand.text}`)
      }
      .padding({ left: 8, right: 8 })
      .alignItems(VerticalAlign.Center)
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .height(48)
    .backgroundColor(BG_BAR)
  }

  @Builder
  KeyCap(label: string, weight: number, bg: string, onTap: (ch: string) => void) {
    Text(label)
      .fontSize(20)
      .fontColor(FG_TEXT)
      .textAlign(TextAlign.Center)
      .backgroundColor(bg)
      .borderRadius(8)
      .layoutWeight(weight)
      .height(46)
      .margin(3)
      .onClick(() => {
        onTap(label);
      })
  }

  @Builder
  LetterRows() {
    Column({ space: 2 }) {
      Row({ space: 2 }) {
        ForEach(this.numericMode ? NUM_ROW_1 : LETTER_ROW_1, (ch: string) => {
          this.KeyCap(ch, 1, BG_KEY, (c: string): void => {
            this.onKeyTap(c);
          })
        }, (ch: string) => ch)
      }
      Row({ space: 2 }) {
        Blank().layoutWeight(0.5)
        ForEach(this.numericMode ? NUM_ROW_2 : LETTER_ROW_2, (ch: string) => {
          this.KeyCap(ch, 1, BG_KEY, (c: string): void => {
            this.onKeyTap(c);
          })
        }, (ch: string) => ch)
        Blank().layoutWeight(0.5)
      }
      Row({ space: 2 }) {
        Blank().layoutWeight(1)
        ForEach(this.numericMode ? NUM_ROW_3 : LETTER_ROW_3, (ch: string) => {
          this.KeyCap(ch, 1, BG_KEY, (c: string): void => {
            this.onKeyTap(c);
          })
        }, (ch: string) => ch)
        Blank().layoutWeight(1)
      }
    }
  }

  private onKeyTap(ch: string): void {
    if (this.numericMode) {
      mixedController.onNumeric(ch);
    } else {
      mixedController.onChar(ch);
    }
  }

  build() {
    Column() {
      this.CandidateBar()
      Column({ space: 2 }) {
        this.LetterRows()
        Row({ space: 2 }) {
          this.KeyCap(this.numericMode ? 'abc' : '?123', 1.5, BG_FUNC, (): void => {
            this.numericMode = !this.numericMode;
          })
          this.KeyCap('，', 1, BG_KEY, (c: string): void => {
            mixedController.onPunctuation(c);
          })
          this.KeyCap('空白', 4, BG_KEY, (): void => {
            mixedController.onSpace();
          })
          this.KeyCap('。', 1, BG_KEY, (): void => {
            mixedController.onPunctuation('。');
          })
          this.KeyCap('⏎', 1.5, BG_FUNC, (): void => {
            mixedController.onEnter();
          })
          this.KeyCap('⌫', 1.5, BG_FUNC, (): void => {
            mixedController.onBackspace();
          })
        }
      }
      .padding({ left: 4, right: 4, top: 2, bottom: 6 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG_PANEL)
    .alignItems(HorizontalAlign.Start)
  }
}
