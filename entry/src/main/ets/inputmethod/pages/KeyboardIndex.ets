import { Cand } from '../model/DictEngine';
import { mixedController } from '../model/MixedController';
import { window, display } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

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
// Fallback dock/taskbar height (vp) for 2-in-1 PC mode when the system
// neither places the panel above the dock nor reports it via avoid-area.
// Tune this so the candidate bar sits just above the dock with no overlap.
const DOCK_FALLBACK_VP: number = 40;
// Collapsed (physical-keyboard) candidate strip geometry. The IME panel is
// The floating candidate panel is COLLAPSED_VP tall; STRIP_BAND_VP is only
// a position input for Panel.moveTo (taskbar height), never window height.
// Legacy note (kept for history): a previous experiment
// the window and the band underneath stays transparent + touch-passing. The
// band must clear the 2-in-1 taskbar completely (SCBSmartDock window is
// 125 px tall at density 1.9 => 66 vp), otherwise the strip overlaps it.
const STRIP_VP: number = 60; // must match COLLAPSED_VP in MixedController.ets
const STRIP_BAND_VP: number = 66; // >= taskbar window height (125 px @ 1.9)

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
  @State collapsed: boolean = false;
  @State physicalMode: boolean = false;
  @State physicalPinyin: boolean = true;
  @State selCand: number = -1;
  @State expandedScreen: boolean = false;
  @State bottomInset: number = 0;

  private repeatTimer: number = -1;
  private repeating: string = '';
  private chipScroller: Scroller = new Scroller();
  // handle to the floating panel window, cached for moveWindowTo / startMoving
  private kbWindow: window.Window | undefined;
  // horizontal offset (vp) of the candidate strip inside the transparent
  // band; -1 = not yet placed (defaults to right-aligned)
  // collapsed-state latch for the one-shot dock-inset trigger
  private collapsedSeen: boolean = false;
  // geometry key under which the floating bar was last auto-positioned, so a
  // user drag is not snapped back on every area-change callback
  private lastPlacedKey: string = '';

  aboutToAppear(): void {
    this.expandedScreen = mixedController.isExpandedScreen();
    mixedController.setUiListener((comp: string, cands: Cand[], predicting: boolean,
      shift: boolean, rowHeight: number, expanded: boolean,
      collapsed: boolean, physicalMode: boolean, pinyinOn: boolean, sel: number) => {
      this.composition = comp;
      this.candidates = cands;
      this.predicting = predicting;
      this.shiftOn = shift;
      this.rowHeight = rowHeight;
      this.expandedScreen = expanded;
      this.collapsed = collapsed;
      this.physicalMode = physicalMode;
      this.physicalPinyin = pinyinOn;
      this.selCand = sel;
      if (collapsed && (!this.collapsedSeen || !this.kbWindow)) {
        this.collapsedSeen = true;
        // (re)acquire the bar window handle: the IME process restarts on
        // reinstall and the cached handle goes stale — without it the grip
        // cannot start a system drag
        this.setupDockAwareness();
      }
      if (sel >= 0) {
        // keep the highlighted candidate visible (status chip occupies ListItem 0 when shown)
        const idx: number = sel + ((comp.length > 0 || predicting) ? 1 : 0);
        setTimeout(() => {
          try {
            this.chipScroller.scrollToIndex(idx, false, ScrollAlign.CENTER);
          } catch (e) {
            console.warn(`chips scrollToIndex failed ${idx}`);
          }
        }, 30);
      }
    });
    this.setupDockAwareness();
  }

  /**
   * On 2-in-1 with a physical keyboard attached the candidate bar is a slim
   * floating freeform window: cache its handle, park it just above the desktop
   * dock, and expose a drag handle (startMoving) so the user can place it
   * anywhere. The full keyboard (rare here) still uses the avoid-area inset.
   */
  private setupDockAwareness(): void {
    setTimeout(() => {
      this.refreshDockInset();
    }, 50);
  }

  /**
   * Get a usable handle to the floating panel window. The page's own host
   * context cannot see it (getLastWindow fails 1300002 in panel pages), so
   * try the IME extension context first, then the host, then any window of
   * the IME bundle.
   */
  private async acquireBarWindow(): Promise<window.Window | undefined> {
    const ime = mixedController.getExtensionContext() as common.BaseContext | undefined;
    const host = this.getUIContext().getHostContext() as common.BaseContext;
    const candidates: (common.BaseContext | undefined)[] = [ime, host];
    for (const ctx of candidates) {
      if (!ctx) {
        continue;
      }
      try {
        const win = await window.getLastWindow(ctx);
        console.info('dock: bar window via getLastWindow');
        return win;
      } catch (e) {
        console.warn(`getLastWindow failed ${(e as BusinessError).code}`);
      }
    }
    if (ime) {
      // the panel window is named softKeyboard<N>; N increments every time
      // the panel is re-created, so scan for a live one
      for (let i = 1; i <= 9; i++) {
        const n: string = `softKeyboard${i}`;
        try {
          const win = window.findWindow(n);
          console.info(`dock: bar window via findWindow(${n})`);
          return win;
        } catch (e) {
          // try the next candidate name
        }
      }
    }
    return undefined;
  }

  private refreshDockInset(): void {
    console.info(`refreshDockInset: collapsed=${this.collapsed} inset=${this.bottomInset}`);
    if (this.collapsed) {
      // FIXED panel windows are invisible to findWindow/getLastWindow, so no
      // handle and no avoid-area query: use the fallback band directly. The
      // window grows by it, the strip renders at the TOP (above the
      // taskbar), and the taskbar zone stays transparent + touch-passing.
      console.info('refreshDockInset: collapsed path, applying band');
      if (Math.abs(STRIP_BAND_VP - this.bottomInset) >= 1) {
        this.bottomInset = STRIP_BAND_VP;
        mixedController.setBottomInset(STRIP_BAND_VP);
      }
      return;
    }
    this.acquireBarWindow().then((win: window.Window | undefined) => {
      // Only a MEASURED dock justifies the bottom spacer: a fallback here
      // added a phantom blank band on devices without a taskbar (Mate XTs),
      // while real docks (Edge taskbar, 125px) measure well above it.
      if (!win) {
        console.warn('dock: no bar window found; no bottom inset');
        if (this.bottomInset !== 0) {
          this.bottomInset = 0;
          mixedController.setBottomInset(0);
        }
        return;
      }
      this.kbWindow = win;
      const dockPx: number = this.readDockPx(win);
      const insetVp: number = px2vp(dockPx) >= 50 ? Math.round(px2vp(dockPx)) : 0;
      if (Math.abs(insetVp - this.bottomInset) >= 1) {
        this.bottomInset = insetVp;
        mixedController.setBottomInset(insetVp);
      }
    });
  }

  private readDockPx(win: window.Window): number {
    const nav: number =
      win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR).bottomRect.height;
    const sys: number =
      win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).bottomRect.height;
    return nav > sys ? nav : sys;
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
    if (this.predicting) {
      return '聯想';
    }
    return this.composition.length > 0 ? this.composition : 'Mixed KB';
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
    const text: string = this.candidates[index].text;
    // digit shortcuts (and their N. prefix) only apply when a physical
    // keyboard is attached; the soft panel taps candidates directly
    if (!this.physicalMode) {
      return text;
    }
    const n: number = this.candNum(index);
    if (n === 0) {
      return text;
    }
    return n === 10 ? `0.${text}` : `${n}.${text}`;
  }

  /** The grey status chip only earns its space while composing or predicting. */
  private labelVisible(): boolean {
    return this.composition.length > 0 || this.predicting;
  }

  /** Label + candidate chips as a horizontal List: supports scrollToIndex. */
  @Builder
  Chips() {
    List({ space: 4, scroller: this.chipScroller }) {
      if (this.labelVisible()) {
        ListItem() {
          Text(this.barLabel())
            .fontSize(14)
            .fontColor('#8A8F99')
            .backgroundColor('#E2E5EB')
            .borderRadius(6)
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        }
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

  /** Celia-style minimise chevron at the LEFT of the candidate bar: hides
   * the panel until the next input focus. Only on soft-keyboard-only
   * devices — with a physical keyboard the bar/collapse pair is used. */
  @Builder
  MinimizeButton() {
    Text('⌄')
      .fontSize(18)
      .fontColor(FG_TEXT)
      .textAlign(TextAlign.Center)
      .backgroundColor(this.keyBg(BG_FUNC, 'minimise'))
      .borderRadius(6)
      .width(44)
      .height(36)
      .margin({ right: 4 })
      .onTouch((e: TouchEvent) => {
        if (e.type === TouchType.Down) {
          mixedController.minimizePanel();
        }
      })
  }

  @Builder
  CandidateBar() {
    Row() {
      if (!this.physicalMode) {
        this.MinimizeButton()
      }
      this.Chips()
      if (this.physicalMode) {
        this.CollapseButton('⌄')
      }
    }
    .width('100%')
    .height(36)
    .backgroundColor(BG_BAR)
    .alignItems(VerticalAlign.Center)
  }

  /** Full-row 漢/EN key (Celia puts its 英/中 toggle second from left). */
  @Builder
  PinyinKey() {
    Text(this.physicalPinyin ? '漢' : 'EN')
      .fontSize(16)
      .fontColor(this.physicalPinyin ? '#2B5FBF' : '#8A8F99')
      .textAlign(TextAlign.Center)
      .backgroundColor(this.keyBg(BG_FUNC, 'pinyin_row'))
      .borderRadius(8)
      .layoutWeight(this.expandedScreen ? 1 : 1.5)
      .height(this.rowHeight - 12)
      .margin({ left: 3, right: 3, top: 6, bottom: 6 })
      .onTouch((e: TouchEvent) => {
        this.startPress('pinyin_row', e, () => {
          mixedController.onTogglePhysicalPinyin();
        }, false);
      })
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

  @Builder
  DragHandle() {
    Text('⠿')
      .fontSize(18)
      .fontColor(FG_TEXT)
      .textAlign(TextAlign.Center)
      .backgroundColor(this.keyBg(BG_FUNC, 'drag'))
      .borderRadius(8)
      .width(44)
      .height('90%')
      .margin({ left: 4, right: 4 })
      .onTouch((e: TouchEvent) => {
        if (e.type !== TouchType.Down) {
          return;
        }
        const win = this.kbWindow;
        if (win) {
          win.startMoving().then(() => {
            console.info('bar startMoving ok');
          }).catch((err: BusinessError) => {
            console.warn(`startMoving failed ${err.code}`);
          });
        } else {
          this.refreshDockInset();
        }
      })
  }

  /** Candidate bar while a physical keyboard is attached: fills the narrow
   * FLG_FLOATING panel window, which the controller docks bottom-left above
   * the taskbar via Panel.moveTo(). */
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
    .borderRadius(16)
    .padding({ left: 12, right: 8 })
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
      .height(this.rowHeight - 12)
      .margin({ left: 3, right: 3, top: 6, bottom: 6 })
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
      .height(this.rowHeight - 12)
      .margin({ left: 3, right: 3, top: 6, bottom: 6 })
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
      .height(this.rowHeight - 12)
      .margin({ left: 3, right: 3, top: 6, bottom: 6 })
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
      .height(this.rowHeight - 12)
      .margin({ left: 3, right: 3, top: 6, bottom: 6 })
      .onTouch((e: TouchEvent) => {
        this.startPress('mode', e, () => {
          this.numericMode = !this.numericMode;
          this.symbolPage = 0;
        }, false);
      })
  }

  @Builder
  SpaceKey() {
    Text('空白')
      .fontSize(20)
      .fontColor(FG_TEXT)
      .textAlign(TextAlign.Center)
      .backgroundColor(this.keyBg(BG_KEY, 'space'))
      .borderRadius(8)
      .layoutWeight(this.expandedScreen ? 6 : 5)
      .height(this.rowHeight - 12)
      .margin({ left: 3, right: 3, top: 6, bottom: 6 })
      .onTouch((e: TouchEvent) => {
        // no repeat: a held Space should stay one space
        this.startPress('space', e, () => {
          mixedController.onSpace();
        }, false);
      })
  }

  @Builder
  EnterKey() {
    Text(this.shiftOn ? '換行' : '⏎')
      .fontSize(this.shiftOn ? 15 : 20)
      .fontColor(FG_TEXT)
      .textAlign(TextAlign.Center)
      .backgroundColor(this.keyBg(BG_FUNC, 'enter'))
      .borderRadius(8)
      .layoutWeight(this.expandedScreen ? 1 : 1.5)
      .height(this.rowHeight - 12)
      .margin({ left: 3, right: 3, top: 6, bottom: 6 })
      .onTouch((e: TouchEvent) => {
        this.startPress('enter', e, () => {
          // Shift+Enter forces a literal line break; plain Enter fires the
          // editor's declared action (send/search/next/newline)
          mixedController.onEnter(this.shiftOn);
        }, true);
      })
  }

  /** Key legend: under Shift the punctuation keys advertise their full-width output. */
  private puncLabel(ch: string): string {
    if (!this.shiftOn) {
      return ch;
    }
    if (ch === ',') {
      return '，';
    }
    if (ch === '.') {
      return '。';
    }
    return ch;
  }

  @Builder
  PuncKey(ch: string) {
    Text(this.puncLabel(ch))
      .fontSize(20)
      .fontColor(FG_TEXT)
      .textAlign(TextAlign.Center)
      .backgroundColor(this.keyBg(BG_KEY, `p_${ch}`))
      .borderRadius(8)
      .layoutWeight(1)
      .height(this.rowHeight - 12)
      .margin({ left: 3, right: 3, top: 6, bottom: 6 })
      .onTouch((e: TouchEvent) => {
        this.startPress(`p_${ch}`, e, () => {
          mixedController.onPunctuation(ch);
        }, true);
      })
  }

  @Builder
  LetterRows() {
    Column() {
      Row() {
        ForEach(this.row1(), (ch: string, index: number) => {
          this.LetterKey(ch, this.numericMode)
        }, (ch: string, index: number) => `${this.rowTag()}_${index}_${ch}`)
      }
      Row() {
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
      Row() {
        this.ShiftKey()
        ForEach(this.row3(), (ch: string, index: number) => {
          this.LetterKey(ch, this.numericMode)
        }, (ch: string, index: number) => `${this.rowTag()}_${index}_${ch}`)
        this.BackKey()
      }
    }
  }

  build() {
    if (this.collapsed) {
      // the narrow FLG_FLOATING window IS the candidate bar; the controller
      // docks it bottom-left above the taskbar via Panel.moveTo()
      Column() {
        this.CollapsedBar()
      }
      .width('100%')
      .height('100%')
      .backgroundColor(BG_BAR)
      .alignItems(HorizontalAlign.Start)
      .onAreaChange((_oldValue: Area, newValue: Area) => {
        const w: number = Number(newValue.width);
        const h: number = Number(newValue.height);
        if (h > 0 && w > 0) {
          this.refreshDockInset();
          mixedController.onContentArea(w, h);
        }
      })
    } else {
      Column() {
        Column() {
          this.CandidateBar()
          Column() {
            this.LetterRows()
            Row() {
              // Celia bottom row order (measured on-device): 符号 | 英/中 | , | space | . | 123 | Enter
              this.ModeKey()
              this.PinyinKey()
              this.PuncKey(',')
              this.SpaceKey()
              this.PuncKey('.')
              this.EnterKey()
            }
          }
          .padding(this.expandedScreen ? { left: 24, right: 24, top: 2, bottom: 2 }
            : { left: 4, right: 4, top: 2, bottom: 2 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .backgroundColor(BG_PANEL)
        // transparent strip the height of the dock / navigation indicator, so
        // the opaque keyboard sits above it instead of covering the dock
        Blank().height(this.bottomInset)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Start)
      .alignItems(HorizontalAlign.Start)
      .backgroundColor(Color.Transparent)
      .onAreaChange((_oldValue: Area, newValue: Area) => {
        const w: number = Number(newValue.width);
        const h: number = Number(newValue.height);
        if (h > 0 && w > 0) {
          this.refreshDockInset();
          mixedController.onContentArea(w, h);
        }
      })
    }
  }
}
