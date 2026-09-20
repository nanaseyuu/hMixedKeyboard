import { Cand } from '../model/DictEngine';
import { mixedController } from '../model/MixedController';

const LETTER_ROW_1: string[] = ['q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p'];
const LETTER_ROW_2: string[] = ['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l'];
const LETTER_ROW_3: string[] = ['z', 'x', 'c', 'v', 'b', 'n', 'm'];
// symbol page 1: numbers and everyday symbols
const NUM_ROW_1: string[] = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'];
const NUM_ROW_2: string[] = ['@', '#', '$', '%', '&', '-', '+', '(', ')'];
const NUM_ROW_3: string[] = ['*', '"', "'", ':', ';', '!', '?'];
// symbol page 2: programming / typographic symbols (page 1/2 switch)
const SYM2_ROW_1: string[] = ['[', ']', '{', '}', '<', '>', '/', '\\', '|', '~'];
const SYM2_ROW_2: string[] = ['^', '`', '=', '_', '€', '£', '°', '±', '×'];
const SYM2_ROW_3: string[] = ['÷', '…', '′', '″', '§', '←', '→'];

const BG_PANEL: string = '#E4E7EC';
const BG_BAR: string = '#F7F8FA';
const BG_KEY: string = '#FFFFFF';
const BG_FUNC: string = '#C9CEDA';
const BG_FUNC_ON: string = '#B8C6E8';
const BG_PRESSED: string = '#B4BAC8';
const FG_TEXT: string = '#1A1C1E';

@Entry
@Component
struct KeyboardIndex {
  @State composition: string = '';
  @State candidates: Cand[] = [];
  @State predicting: boolean = false;
  @State numericMode: boolean = false;
  @State symbolPage: number = 0;
  @State shiftOn: boolean = false;
  @State rowHeight: number = 46;
  @State pressedKey: string = '';
  @State voiceOn: boolean = false;
  @State voiceHint: string = '';
  @State collapsed: boolean = false;
  @State physicalMode: boolean = false;

  private voiceTimer: number = -1;
  private voiceFired: boolean = false;

  aboutToAppear(): void {
    mixedController.setUiListener((comp: string, cands: Cand[], predicting: boolean,
      shift: boolean, rowHeight: number, voiceOn: boolean, voiceHint: string,
      collapsed: boolean, physicalMode: boolean) => {
      this.composition = comp;
      this.candidates = cands;
      this.predicting = predicting;
      this.shiftOn = shift;
      this.rowHeight = rowHeight;
      this.voiceOn = voiceOn;
      this.voiceHint = voiceHint;
      this.collapsed = collapsed;
      this.physicalMode = physicalMode;
    });
  }

  aboutToDisappear(): void {
    mixedController.setUiListener(undefined);
  }

  /** Press feedback: grey the key out while it is held down. */
  private onPress(id: string, e: TouchEvent): void {
    if (e.type === TouchType.Down) {
      this.pressedKey = id;
    } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
      if (this.pressedKey === id) {
        this.pressedKey = '';
      }
    }
  }

  private keyBg(normal: string, id: string): string {
    return this.pressedKey === id ? BG_PRESSED : normal;
  }

  private row1(): string[] {
    if (this.numericMode) {
      return this.symbolPage === 0 ? NUM_ROW_1 : SYM2_ROW_1;
    }
    return LETTER_ROW_1;
  }

  private row2(): string[] {
    if (this.numericMode) {
      return this.symbolPage === 0 ? NUM_ROW_2 : SYM2_ROW_2;
    }
    return LETTER_ROW_2;
  }

  private row3(): string[] {
    if (this.numericMode) {
      return this.symbolPage === 0 ? NUM_ROW_3 : SYM2_ROW_3;
    }
    return LETTER_ROW_3;
  }

  private rowTag(): string {
    return this.numericMode ? `s${this.symbolPage}` : 'l';
  }

  private barLabel(): string {
    if (this.voiceOn) {
      return '🎤 聆聽中…';
    }
    if (this.voiceHint.length > 0) {
      return this.voiceHint;
    }
    if (this.predicting) {
      return '聯想';
    }
    return this.composition.length > 0 ? this.composition : 'hMixed';
  }

  /** Index of the candidate that Space would commit (first non-raw, else raw). */
  private commitIndex(): number {
    for (let i = 0; i < this.candidates.length; i++) {
      if (!this.candidates[i].isRaw) {
        return i;
      }
    }
    return this.candidates.length > 0 ? 0 : -1;
  }

  /** Label + candidate chips, shared by the full bar and the collapsed bar. */
  @Builder
  Chips() {
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
          .backgroundColor(!this.predicting && index === this.commitIndex() ? '#DCE4F7' : Color.Transparent)
          .onClick(() => {
            mixedController.chooseCandidate(index);
          })
      }, (cand: Cand, index: number) => `${index}_${cand.text}`)
    }
    .padding({ left: 8, right: 8 })
    .alignItems(VerticalAlign.Center)
  }

  /** ^ when collapsed (restore keys) / ⌄ when expanded (collapse to bar). */
  @Builder
  CollapseButton(symbol: string) {
    Text(symbol)
      .fontSize(18)
      .fontColor(FG_TEXT)
      .textAlign(TextAlign.Center)
      .backgroundColor(this.keyBg(BG_FUNC, 'collapse'))
      .borderRadius(6)
      .width(44)
      .height(36)
      .margin({ right: 6 })
      .onTouch((e: TouchEvent) => {
        this.onPress('collapse', e);
      })
      .onClick(() => {
        mixedController.onToggleCollapse();
      })
  }

  @Builder
  CandidateBar() {
    Row() {
      Scroll() {
        this.Chips()
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .height('100%')
      if (this.physicalMode) {
        this.CollapseButton('⌄')
      }
    }
    .width('100%')
    .height(48)
    .backgroundColor(BG_BAR)
    .alignItems(VerticalAlign.Center)
  }

  /** Slim bar while a physical keyboard is attached: chips + ^ restore. */
  @Builder
  CollapsedBar() {
    Row() {
      Scroll() {
        this.Chips()
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .height('100%')
      this.CollapseButton('^')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG_BAR)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  LetterKey(ch: string, num: boolean) {
    Text(num ? ch : (this.shiftOn ? ch.toUpperCase() : ch))
      .fontSize(20)
      .fontColor(FG_TEXT)
      .textAlign(TextAlign.Center)
      .backgroundColor(this.keyBg(BG_KEY, `${this.rowTag()}_${ch}`))
      .borderRadius(8)
      .layoutWeight(1)
      .height(this.rowHeight)
      .margin(3)
      .onTouch((e: TouchEvent) => {
        this.onPress(`${this.rowTag()}_${ch}`, e);
      })
      .onClick(() => {
        if (num) {
          mixedController.onNumeric(ch);
        } else {
          mixedController.onChar(ch);
        }
      })
  }

  @Builder
  ShiftKey() {
    Text(this.numericMode ? `${this.symbolPage + 1}/2` : (this.shiftOn ? '⇪' : '⇧'))
      .fontSize(20)
      .fontColor(FG_TEXT)
      .textAlign(TextAlign.Center)
      .backgroundColor(this.keyBg(this.numericMode ? BG_FUNC_ON : (this.shiftOn ? BG_FUNC_ON : BG_FUNC), 'shift'))
      .borderRadius(8)
      .layoutWeight(1.2)
      .height(this.rowHeight)
      .margin(3)
      .onTouch((e: TouchEvent) => {
        this.onPress('shift', e);
      })
      .onClick(() => {
        if (this.numericMode) {
          this.symbolPage = this.symbolPage === 0 ? 1 : 0;
        } else {
          mixedController.onShift();
        }
      })
  }

  @Builder
  BackKey() {
    Text('⌫')
      .fontSize(20)
      .fontColor(FG_TEXT)
      .textAlign(TextAlign.Center)
      .backgroundColor(this.keyBg(BG_FUNC, 'back'))
      .borderRadius(8)
      .layoutWeight(1.2)
      .height(this.rowHeight)
      .margin(3)
      .onTouch((e: TouchEvent) => {
        this.onPress('back', e);
      })
      .onClick(() => {
        mixedController.onBackspace();
      })
  }

  @Builder
  ModeKey() {
    Text(this.numericMode ? 'abc' : '?123')
      .fontSize(20)
      .fontColor(FG_TEXT)
      .textAlign(TextAlign.Center)
      .backgroundColor(this.keyBg(BG_FUNC, 'mode'))
      .borderRadius(8)
      .layoutWeight(1.5)
      .height(this.rowHeight)
      .margin(3)
      .onTouch((e: TouchEvent) => {
        this.onPress('mode', e);
      })
      .onClick(() => {
        this.numericMode = !this.numericMode;
        this.symbolPage = 0;
      })
  }

  @Builder
  SpaceKey() {
    Text(this.voiceOn ? '🎤 放開結束' : '空白')
      .fontSize(20)
      .fontColor(this.voiceOn ? '#2B5FBF' : FG_TEXT)
      .textAlign(TextAlign.Center)
      .backgroundColor(this.keyBg(BG_KEY, 'space'))
      .borderRadius(8)
      .layoutWeight(5)
      .height(this.rowHeight)
      .margin(3)
      .onTouch((e: TouchEvent) => {
        this.onPress('space', e);
        if (e.type === TouchType.Down) {
          this.voiceFired = false;
          this.voiceTimer = setTimeout(() => {
            this.voiceFired = true;
            mixedController.onVoiceStart();
          }, 450);
        } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
          if (this.voiceTimer !== -1) {
            clearTimeout(this.voiceTimer);
            this.voiceTimer = -1;
          }
          if (this.voiceFired) {
            mixedController.onVoiceStop();
          }
        }
      })
      .onClick(() => {
        if (this.voiceFired) {
          this.voiceFired = false;
          return;
        }
        mixedController.onSpace();
      })
  }

  @Builder
  EnterKey() {
    Text('⏎')
      .fontSize(20)
      .fontColor(FG_TEXT)
      .textAlign(TextAlign.Center)
      .backgroundColor(this.keyBg(BG_FUNC, 'enter'))
      .borderRadius(8)
      .layoutWeight(1.5)
      .height(this.rowHeight)
      .margin(3)
      .onTouch((e: TouchEvent) => {
        this.onPress('enter', e);
      })
      .onClick(() => {
        mixedController.onEnter();
      })
  }

  @Builder
  PuncKey(ch: string) {
    Text(ch)
      .fontSize(20)
      .fontColor(FG_TEXT)
      .textAlign(TextAlign.Center)
      .backgroundColor(this.keyBg(BG_KEY, `p_${ch}`))
      .borderRadius(8)
      .layoutWeight(1)
      .height(this.rowHeight)
      .margin(3)
      .onTouch((e: TouchEvent) => {
        this.onPress(`p_${ch}`, e);
      })
      .onClick(() => {
        mixedController.onPunctuation(ch);
      })
  }

  @Builder
  LetterRows() {
    Column({ space: 2 }) {
      Row({ space: 2 }) {
        ForEach(this.row1(), (ch: string, index: number) => {
          this.LetterKey(ch, this.numericMode)
        }, (ch: string, index: number) => `${this.rowTag()}_${index}_${ch}`)
      }
      Row({ space: 2 }) {
        Blank().layoutWeight(0.5)
        ForEach(this.row2(), (ch: string, index: number) => {
          this.LetterKey(ch, this.numericMode)
        }, (ch: string, index: number) => `${this.rowTag()}_${index}_${ch}`)
        Blank().layoutWeight(0.5)
      }
      Row({ space: 2 }) {
        this.ShiftKey()
        ForEach(this.row3(), (ch: string, index: number) => {
          this.LetterKey(ch, this.numericMode)
        }, (ch: string, index: number) => `${this.rowTag()}_${index}_${ch}`)
        this.BackKey()
      }
    }
  }

  build() {
    Column() {
      if (this.collapsed) {
        this.CollapsedBar()
      } else {
        this.CandidateBar()
        Column({ space: 2 }) {
          this.LetterRows()
          Row({ space: 2 }) {
            this.ModeKey()
            this.PuncKey('，')
            this.SpaceKey()
            this.PuncKey('。')
            this.EnterKey()
          }
        }
        .padding({ left: 4, right: 4, top: 2, bottom: 6 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.collapsed ? BG_BAR : BG_PANEL)
    .alignItems(HorizontalAlign.Start)
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      const h: number = Number(newValue.height);
      if (h > 0) {
        mixedController.onContentArea(h);
      }
    })
  }
}
