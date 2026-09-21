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
// hold a key for 1 s and it keeps repeating every 100 ms until released
const REPEAT_DELAY: number = 1000;
const REPEAT_MS: number = 100;

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
  @State physicalPinyin: boolean = true;
  @State selCand: number = -1;
  @State expandedScreen: boolean = false;

  private voiceTimer: number = -1;
  private voiceFired: boolean = false;
  private repeatTimer: number = -1;
  private repeating: string = '';
  private chipScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.expandedScreen = mixedController.isExpandedScreen();
    mixedController.setUiListener((comp: string, cands: Cand[], predicting: boolean,
      shift: boolean, rowHeight: number, voiceOn: boolean, voiceHint: string,
      collapsed: boolean, physicalMode: boolean, pinyinOn: boolean, sel: number) => {
      this.composition = comp;
      this.candidates = cands;
      this.predicting = predicting;
      this.shiftOn = shift;
      this.rowHeight = rowHeight;
      this.voiceOn = voiceOn;
      this.voiceHint = voiceHint;
      this.collapsed = collapsed;
      this.physicalMode = physicalMode;
      this.physicalPinyin = pinyinOn;
      this.selCand = sel;
      if (sel >= 0) {
        // keep the highlighted candidate visible (first ListItem is the label)
        const idx: number = sel + 1;
        setTimeout(() => {
          try {
            this.chipScroller.scrollToIndex(idx, false, ScrollAlign.CENTER);
          } catch (e) {
            console.warn(`chips scrollToIndex failed ${idx}`);
          }
        }, 30);
      }
    });
  }

  aboutToDisappear(): void {
    this.cancelRepeat();
    mixedController.setUiListener(undefined);
  }

  /** Press feedback + action on touch-down, and hold-to-repeat after 1 s. */
  private startPress(id: string, e: TouchEvent, action: () => void, repeat: boolean): void {
    if (e.type === TouchType.Down) {
      if (this.pressedKey === id) {
        return; // duplicate Down within the same press: ignore
      }
      this.cancelRepeat();
      this.pressedKey = id;
      action();
      if (repeat) {
        this.repeating = id;
        const tick = (): void => {
          if (this.repeating !== id) {
            return;
          }
          action();
          this.repeatTimer = setTimeout(tick, REPEAT_MS);
        };
        this.repeatTimer = setTimeout(tick, REPEAT_DELAY);
      }
    } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
      if (this.pressedKey === id) {
        this.pressedKey = '';
      }
      if (this.repeating === id) {
        this.cancelRepeat();
      }
    }
  }

  private cancelRepeat(): void {
    if (this.repeatTimer !== -1) {
      clearTimeout(this.repeatTimer);
      this.repeatTimer = -1;
    }
    this.repeating = '';
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

  /** Keyboard number shown on a candidate (1..9, 0 for the tenth); 0 = none. */
  private candNum(index: number): number {
    if (this.candidates[index].isRaw) {
      return 0;
    }
    let n: number = 0;
    for (let i = 0; i <= index; i++) {
      if (!this.candidates[i].isRaw) {
        n++;
      }
    }
    return n <= 10 ? n : 0;
  }

  private candLabel(index: number): string {
    const n: number = this.candNum(index);
    const text: string = this.candidates[index].text;
    if (n === 0) {
      return text;
    }
    return n === 10 ? `0.${text}` : `${n}.${text}`;
  }

  /** Label + candidate chips as a horizontal List: supports scrollToIndex. */
  @Builder
  Chips() {
    List({ space: 4, scroller: this.chipScroller }) {
      ListItem() {
        Text(this.barLabel())
          .fontSize(14)
          .fontColor('#8A8F99')
          .backgroundColor('#E2E5EB')
          .borderRadius(6)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      }
      ForEach(this.candidates, (cand: Cand, index: number) => {
        ListItem() {
          Text(this.candLabel(index))
            .fontSize(22)
            .fontColor(index === this.selCand ? '#FFFFFF' : (cand.simplified ? '#5B6472' : FG_TEXT))
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .borderRadius(6)
            .backgroundColor(index === this.selCand ? '#2B5FBF'
              : (!this.predicting && index === this.commitIndex() ? '#DCE4F7' : Color.Transparent))
            .onClick(() => {
              mixedController.chooseCandidate(index);
            })
        }
      }, (cand: Cand, index: number) => `${index}_${cand.text}`)
    }
    .listDirection(Axis.Horizontal)
    .scrollBar(BarState.Off)
    .alignListItem(ListItemAlign.Center)
    .edgeEffect(EdgeEffect.None)
    .layoutWeight(1)
    .width('100%')
    .height('100%')
    .padding({ left: 8, right: 8 })
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
        this.startPress('collapse', e, () => {
          mixedController.onToggleCollapse();
        }, false);
      })
  }

  @Builder
  CandidateBar() {
    Row() {
      this.Chips()
      if (this.physicalMode) {
        this.CollapseButton('⌄')
      }
    }
    .width('100%')
    .height(48)
    .backgroundColor(BG_BAR)
    .alignItems(VerticalAlign.Center)
  }

  /** 漢 = physical keys feed the pinyin engine; EN = keys go to the app. */
  @Builder
  PinyinModeButton() {
    Text(this.physicalPinyin ? '漢' : 'EN')
      .fontSize(16)
      .fontColor(this.physicalPinyin ? '#2B5FBF' : '#8A8F99')
      .textAlign(TextAlign.Center)
      .backgroundColor(this.keyBg(BG_FUNC, 'pinyin'))
      .borderRadius(6)
      .width(40)
      .height(36)
      .margin({ right: 4 })
      .onTouch((e: TouchEvent) => {
        this.startPress('pinyin', e, () => {
          mixedController.onTogglePhysicalPinyin();
        }, false);
      })
  }

  /** Slim bar while a physical keyboard is attached: chips + ^ restore. */
  @Builder
  CollapsedBar() {
    Row() {
      this.Chips()
      if (this.physicalMode) {
        this.PinyinModeButton()
      }
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
      .margin(this.expandedScreen ? 0 : 3)
      .onTouch((e: TouchEvent) => {
        this.startPress(`${this.rowTag()}_${ch}`, e, () => {
          if (num) {
            mixedController.onNumeric(ch);
          } else {
            mixedController.onChar(ch);
          }
        }, true);
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
      .layoutWeight(this.expandedScreen ? 1.35 : 1.2)
      .height(this.rowHeight)
      .margin(this.expandedScreen ? 0 : 3)
      .onTouch((e: TouchEvent) => {
        this.startPress('shift', e, () => {
          if (this.numericMode) {
            this.symbolPage = this.symbolPage === 0 ? 1 : 0;
          } else {
            mixedController.onShift();
          }
        }, false);
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
      .layoutWeight(this.expandedScreen ? 1.55 : 1.2)
      .height(this.rowHeight)
      .margin(this.expandedScreen ? 0 : 3)
      .onTouch((e: TouchEvent) => {
        this.startPress('back', e, () => {
          mixedController.onBackspace();
        }, true);
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
      .layoutWeight(this.expandedScreen ? 1 : 1.5)
      .height(this.rowHeight)
      .margin(this.expandedScreen ? 0 : 3)
      .onTouch((e: TouchEvent) => {
        this.startPress('mode', e, () => {
          this.numericMode = !this.numericMode;
          this.symbolPage = 0;
        }, false);
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
      .layoutWeight(this.expandedScreen ? 6 : 5)
      .height(this.rowHeight)
      .margin(this.expandedScreen ? 0 : 3)
      .onTouch((e: TouchEvent) => {
        // Space never repeats: a held Space belongs to voice input instead
        if (e.type === TouchType.Down) {
          if (this.pressedKey === 'space') {
            return;
          }
          this.pressedKey = 'space';
          this.voiceFired = false;
          this.voiceTimer = setTimeout(() => {
            this.voiceFired = true;
            mixedController.onVoiceStart();
          }, 450);
        } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
          if (this.pressedKey === 'space') {
            this.pressedKey = '';
          }
          if (this.voiceTimer !== -1) {
            clearTimeout(this.voiceTimer);
            this.voiceTimer = -1;
          }
          if (this.voiceFired) {
            this.voiceFired = false;
            mixedController.onVoiceStop();
          } else if (e.type === TouchType.Up) {
            mixedController.onSpace();
          }
        }
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
      .layoutWeight(this.expandedScreen ? 1 : 1.5)
      .height(this.rowHeight)
      .margin(this.expandedScreen ? 0 : 3)
      .onTouch((e: TouchEvent) => {
        this.startPress('enter', e, () => {
          mixedController.onEnter();
        }, true);
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
      .margin(this.expandedScreen ? 0 : 3)
      .onTouch((e: TouchEvent) => {
        this.startPress(`p_${ch}`, e, () => {
          mixedController.onPunctuation(ch);
        }, true);
      })
  }

  @Builder
  LetterRows() {
    Column({ space: this.expandedScreen ? 10 : 2 }) {
      Row({ space: this.expandedScreen ? 10 : 2 }) {
        ForEach(this.row1(), (ch: string, index: number) => {
          this.LetterKey(ch, this.numericMode)
        }, (ch: string, index: number) => `${this.rowTag()}_${index}_${ch}`)
      }
      Row({ space: this.expandedScreen ? 10 : 2 }) {
        if (!this.expandedScreen) {
          Blank().layoutWeight(0.5)
        }
        ForEach(this.row2(), (ch: string, index: number) => {
          this.LetterKey(ch, this.numericMode)
        }, (ch: string, index: number) => `${this.rowTag()}_${index}_${ch}`)
        if (!this.expandedScreen) {
          Blank().layoutWeight(0.5)
        }
      }
      .padding(this.expandedScreen ? { left: 70, right: 70 } : { left: 0, right: 0 })
      Row({ space: this.expandedScreen ? 10 : 2 }) {
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
        Column({ space: this.expandedScreen ? 10 : 2 }) {
          this.LetterRows()
          Row({ space: this.expandedScreen ? 10 : 2 }) {
            this.ModeKey()
            this.PuncKey('，')
            this.SpaceKey()
            this.PuncKey('。')
            this.EnterKey()
          }
        }
        .padding(this.expandedScreen ? { left: 24, right: 24, top: 0, bottom: 34 }
          : { left: 4, right: 4, top: 2, bottom: 6 })
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
