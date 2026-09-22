import { inputMethodEngine, InputMethodExtensionContext } from '@kit.IMEKit';
import { display } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import inputDevice from '@ohos.multimodalInput.inputDevice';
import { KeyEvent as PhysKeyEvent } from '@ohos.multimodalInput.keyEvent';
import { Cand, dictEngine, LookupResult } from './DictEngine';

export type UiListener =
  (composition: string, candidates: Cand[], predicting: boolean, shift: boolean, rowHeight: number,
    collapsed: boolean, physicalMode: boolean, pinyinOn: boolean, sel: number) => void;

const TAG: string = 'MixedController';
// fixed chrome above/below the key rows: candidate bar + row gaps + padding
const NON_ROW_VP: number = 86;
const MIN_ROW_VP: number = 24;
const MAX_ROW_VP: number = 46;
// unfolded (bi-fold / tri-fold) screens get Celia-sized keys: measured Celia
// runs ~320vp top-to-bottom on both unfolded panels at density 2.875, i.e.
// ~57vp rows; the folded cover screen (short axis ~350vp) keeps the compact
// MAX_ROW_VP sizing
const EXPANDED_ROW_VP: number = 57;
const EXPANDED_MIN_SHORT_AXIS_VP: number = 550;
// Celia metrics measured on the MatePad Pro (2880x1920px, density 2): the
// keyboard occupies the bottom 768px (384vp) — candidate bar 96px (48vp),
// four 138px (68vp) key rows at 156px pitch (10vp gaps), and a 66px (33vp)
// bottom pad that keeps the space key clear of the system gesture pill (y1864).
const CELIA_CHROME_VP: number = 112; // 48 bar + 3 row gaps + 34 bottom pad
const CELIA_ROW_VP: number = 68;
const CELIA_PORTRAIT_RATE: number = 0.40;
// Physical keyboards (MatePad Edge share, Bluetooth/folio): the full panel
// used to auto-hide on connect, which made the keyboard unrecoverable when
// the shared mouse pointer leaves the screen. Policy now: collapse to a slim
// candidate bar with a ^ restore arrow (tap ^ for the keys, ⌄ to collapse),
// and auto re-show if the bar ever gets hidden while an editor is attached.
const PHYSICAL_KB_PIN_ENABLED: boolean = true;
const COLLAPSED_VP: number = 60;
// physical key capture via KeyboardDelegate.on('keyEvent'): with the pad's
// keyboard attached, typed letters build the pinyin composition and the
// candidate bar offers Chinese, while Space/Backspace/Enter act on it.
// The 漢/EN toggle hands keys back to the app for plain English typing.
const PHYSICAL_KEY_CAPTURE_ENABLED: boolean = true;
// multimodal KeyCode values (OpenHarmony numbering)
const KC_0: number = 2000;
const KC_9: number = 2009;
const KC_UP: number = 2012;
const KC_DOWN: number = 2013;
const KC_LEFT: number = 2014;
const KC_RIGHT: number = 2015;
const KC_A: number = 2017;
const KC_Z: number = 2042;
const KC_SPACE: number = 2050;
const KC_ENTER: number = 2054;
const KC_DEL: number = 2055;
const KEY_ACTION_PRESS: number = 1;

/**
 * Creates the soft-keyboard panel, talks to the input client and keeps the
 * composition/candidate state shared with the keyboard page.
 */
class MixedController {
  private context: InputMethodExtensionContext | undefined;
  private panel: inputMethodEngine.Panel | undefined;
  private kbController: inputMethodEngine.KeyboardController | undefined;
  private inputClient: inputMethodEngine.InputClient | undefined;
  private uiListener: UiListener | undefined;
  private panelWidth: number = 0;
  private panelHeight: number = 0;
  private panelWidthPx: number = 0;
  private panelHeightPx: number = 0;
  private densityPx: number = 1;
  private rowHeight: number = 46;
  private measuredHeight: number = 0;
  private calibAttempts: number = 0;

  private composition: string = '';
  private baseCands: Cand[] = [];
  private candidates: Cand[] = [];
  private predicting: boolean = false;
  private shiftOn: boolean = false;

  // large (tablet / unfolded) screens render with the Celia geometry
  private expandedScreen: boolean = false;

  public isExpandedScreen(): boolean {
    return this.expandedScreen;
  }

  // physical keyboard policy: pin the soft panel while a shared keyboard is attached
  private physicalKbActive: boolean = false;
  private kbExpanded: boolean = false;
  private basePanelHeight: number = 270;
  private panelShown: boolean = false;
  // true = letters feed the pinyin engine; false = EN mode, letters commit raw
  private physicalPinyin: boolean = true;
  // index (into candidates) highlighted via arrow keys; -1 = nothing picked
  private selCand: number = -1;

  /**
   * Arrow-key candidate navigation over all candidates, including the
   * un-numbered raw-English chip (first stop). +1 next, -1 previous,
   * 0 first, 2 last. Returns false (key passes to the editor) when the
   * candidate list is empty.
   */
  private moveSel(delta: number): boolean {
    const idxs: number[] = [];
    for (let i = 0; i < this.candidates.length; i++) {
      idxs.push(i);
    }
    if (idxs.length === 0) {
      return false;
    }
    let pos: number = idxs.indexOf(this.selCand);
    if (delta === 0) {
      pos = 0;
    } else if (delta === 2) {
      pos = idxs.length - 1;
    } else if (pos < 0) {
      pos = 0;
    } else {
      pos = Math.min(Math.max(pos + delta, 0), idxs.length - 1);
    }
    this.selCand = idxs[pos];
    this.notifyUi();
    return true;
  }

  public isPhysicalPinyin(): boolean {
    return this.physicalPinyin;
  }

  /** 漢/EN toggle (bottom-row key / collapsed bar): EN commits letters raw. */
  public onTogglePhysicalPinyin(): void {
    this.physicalPinyin = !this.physicalPinyin;
    this.selCand = -1;
    if (!this.physicalPinyin && this.composition.length > 0) {
      this.composition = '';
      this.baseCands = [];
      this.candidates = [];
      this.predicting = false;
    }
    console.info(`${TAG} physical pinyin mode -> ${this.physicalPinyin}`);
    this.notifyUi();
  }

  /**
   * KeyboardDelegate keyEvent hook: physical keystrokes while our IME is
   * active. Letters build the composition (and are consumed so the editor
   * does not also receive the raw text); Space/Backspace/Enter act on a
   * pending composition, otherwise they pass through untouched.
   */
  private onPhysicalKeyEvent(ev: PhysKeyEvent): boolean {
    if (ev.action !== KEY_ACTION_PRESS || !this.inputClient) {
      return false;
    }
    const code: number = ev.key.code as number;
    // Ctrl+Space toggles 漢/EN in both directions (checked before the EN
    // pass-through, otherwise EN mode could never be left again)
    if (ev.ctrlKey && !ev.altKey && code === KC_SPACE) {
      this.onTogglePhysicalPinyin();
      return true;
    }
    if (!this.physicalPinyin) {
      return false;
    }
    if (ev.ctrlKey || ev.altKey) {
      return false; // other shortcuts belong to the app
    }
    if (code >= KC_0 && code <= KC_9) {
      // number shortcuts 1..9 and 0=10 select the numbered bar candidates
      if (this.composition.length === 0 && !this.predicting) {
        return false; // no candidate list: digits type normally
      }
      const n: number = code === KC_0 ? 10 : code - KC_0;
      let seen: number = 0;
      for (let i = 0; i < this.candidates.length; i++) {
        if (!this.candidates[i].isRaw) {
          seen++;
          if (seen === n) {
            this.chooseCandidate(i);
            return true;
          }
        }
      }
      return false;
    }
    if (code >= KC_A && code <= KC_Z) {
      const ch: string = String.fromCharCode(97 + (code - KC_A));
      if (ev.shiftKey || ev.capsLock) {
        this.shiftOn = true;
      }
      this.onChar(ch);
      return true;
    }
    if (code === KC_SPACE) {
      if (this.selCand >= 0 && this.selCand < this.candidates.length) {
        // Space/Enter commit the arrow-highlighted candidate
        this.commitText(this.candidates[this.selCand].text);
        return true;
      }
      if (this.composition.length > 0) {
        // no candidate picked: physical Space accepts the raw English typed,
        // trailing space included (numbers / taps still choose Chinese)
        this.commitText(this.rawCand().text + ' ');
        return true;
      }
      if (this.predicting) {
        // plain space ends the related-word suggestion round
        this.predicting = false;
        this.candidates = [];
        this.notifyUi();
      }
      return false;
    }
    if (code === KC_DEL) {
      if (this.composition.length > 0) {
        this.onBackspace();
        return true;
      }
      return false;
    }
    if (code === KC_RIGHT) {
      return this.moveSel(1);
    }
    if (code === KC_LEFT) {
      return this.moveSel(-1);
    }
    if (code === KC_DOWN) {
      return this.moveSel(0);
    }
    if (code === KC_UP) {
      return this.moveSel(2);
    }
    if (this.composition.length > 0 && ev.unicodeChar >= 33) {
      // any other printable symbol (, . ! ? ...) "sends" the raw English
      // candidate followed by the symbol itself, like classic CJK IMEs
      const ch: string = String.fromCodePoint(ev.unicodeChar);
      this.commitText(this.rawCand().text + ch);
      return true;
    }
    if (code === KC_ENTER) {
      if (this.selCand >= 0 && this.selCand < this.candidates.length) {
        this.commitText(this.candidates[this.selCand].text);
        return true;
      }
      if (this.composition.length > 0) {
        this.onEnter();
        return true;
      }
      return false;
    }
    return false;
  }

  /** true = only the candidate bar should be shown (physical keyboard in use) */
  public isCollapsed(): boolean {
    return this.physicalKbActive && !this.kbExpanded;
  }

  public onCreate(context: InputMethodExtensionContext): void {
    console.info(`${TAG} onCreate enter`);
    this.context = context;
    try {
      dictEngine.setResourceManager(context.resourceManager);
      console.info(`${TAG} onCreate resourceManager set`);
    } catch (e) {
      console.error(`${TAG} setResourceManager failed: ${JSON.stringify(e)}`);
    }
    this.initWindow();
    this.registerListener();
    if (PHYSICAL_KB_PIN_ENABLED) {
      this.registerDeviceListener();
      this.scanPhysicalKeyboard().then((present: boolean) => {
        this.physicalKbActive = present;
        if (present) {
          this.applyPanelSize();
        }
      });
    }
    if (PHYSICAL_KEY_CAPTURE_ENABLED) {
      try {
        inputMethodEngine.getKeyboardDelegate().on('keyEvent',
          (ev: PhysKeyEvent): boolean => this.onPhysicalKeyEvent(ev));
        console.info(`${TAG} physical key capture subscribed`);
      } catch (e) {
        const be = e as BusinessError;
        console.error(`${TAG} keyEvent subscribe failed: ${be.code}`);
      }
    }
    console.info(`${TAG} onCreate done`);
  }

  public onDestroy(): void {
    if (this.panel) {
      inputMethodEngine.getInputMethodAbility().destroyPanel(this.panel).catch((err: BusinessError) => {
        console.error(`${TAG} destroyPanel: ${err.code} ${err.message}`);
      });
      this.panel = undefined;
    }
  }

  /**
   * Derive row height from the available screen so that panelHeight always
   * equals the real content height (no blank area below the keys).
   */
  private applyLayout(): void {
    const dis = display.getDefaultDisplaySync();
    const density: number = dis.densityPixels > 0 ? dis.densityPixels : 1;
    const isLandscape: boolean = dis.width > dis.height;
    const verticalVp: number = Math.floor(dis.height / density);
    const shortAxisVp: number = Math.floor(Math.min(dis.width, dis.height) / density);
    this.expandedScreen = shortAxisVp >= EXPANDED_MIN_SHORT_AXIS_VP;
    let chrome: number = NON_ROW_VP;
    let rowH: number;
    if (this.expandedScreen) {
      // exact Celia geometry (see CELIA_* constants above)
      chrome = CELIA_CHROME_VP;
      if (isLandscape) {
        rowH = CELIA_ROW_VP;
      } else {
        rowH = Math.floor((Math.floor(CELIA_PORTRAIT_RATE * verticalVp) - chrome) / 4);
        if (rowH < 40) {
          rowH = 40;
        }
      }
    } else {
      let budget: number = isLandscape
        ? Math.min(0.5 * verticalVp, NON_ROW_VP + 4 * 30)
        : Math.min(0.42 * verticalVp, NON_ROW_VP + 4 * MAX_ROW_VP);
      rowH = Math.floor((budget - NON_ROW_VP) / 4);
      if (rowH < MIN_ROW_VP) {
        rowH = MIN_ROW_VP;
      } else if (rowH > MAX_ROW_VP) {
        rowH = MAX_ROW_VP;
      }
    }
    this.rowHeight = rowH;
    this.panelWidth = Math.floor(dis.width / density);
    this.basePanelHeight = chrome + rowH * 4;
    // resize() is applied in PHYSICAL pixels, not vp: a resize(350, 270) for
    // 270vp produced a 270-px window (94vp) on a density-2.875 screen.
    this.densityPx = density;
    this.panelWidthPx = dis.width;
    this.applyPanelSize();
    this.measuredHeight = 0;
    this.calibAttempts = 0;
    console.info(`${TAG} applyLayout: ${dis.width}x${dis.height} d${density} row ${rowH}vp panel ${this.panelWidth}x${this.panelHeight}vp (${this.panelWidthPx}x${this.panelHeightPx}px)`);
  }

  /**
   * Effective window size: the full keyboard, or the slim COLLAPSED_VP
   * candidate bar while a physical keyboard is attached.
   */
  private applyPanelSize(): void {
    this.panelHeight = this.isCollapsed() ? COLLAPSED_VP : this.basePanelHeight;
    this.panelHeightPx = Math.round(this.panelHeight * this.densityPx);
    if (this.panel && this.panelShown) {
      this.resizeWithRetry(this.panelWidthPx, this.panelHeightPx, 1);
    }
    this.notifyUi();
  }

  /** ^ / ⌄ tapped on the panel: switch between candidate bar and full keys. */
  public onToggleCollapse(): void {
    this.kbExpanded = !this.kbExpanded;
    console.info(`${TAG} collapse toggle -> expanded=${this.kbExpanded}`);
    this.applyPanelSize();
  }

  /**
   * The keyboard page reports its real rendered height here. Row height is
   * fitted to whatever window the system actually gave us (so rows can never
   * be clipped), and if that window is smaller than requested we re-resize
   * once with a height scaled by the wanted/got ratio (covers unit or clamp
   * differences between our request and the window manager's interpretation).
   */
  public onContentArea(heightVp: number): void {
    if (heightVp <= 0) {
      return;
    }
    if (this.isCollapsed()) {
      // collapsed bar: its height is fixed, no row fitting / calibration
      return;
    }
    this.measuredHeight = heightVp;
    if (!this.expandedScreen) {
      // phone layouts: fit rows to whatever window the system actually gave us
      let rowH: number = Math.floor((heightVp - NON_ROW_VP) / 4);
      if (rowH < MIN_ROW_VP) {
        rowH = MIN_ROW_VP;
      } else if (rowH > MAX_ROW_VP) {
        rowH = MAX_ROW_VP;
      }
      if (rowH !== this.rowHeight) {
        this.rowHeight = rowH;
      }
    }
    console.info(`${TAG} onContentArea measured ${heightVp}vp row ${this.rowHeight}vp`);
    this.notifyUi();
    if (this.panel && this.calibAttempts < 2 && Math.abs(heightVp - this.panelHeight) > 8) {
      this.calibAttempts++;
      let corrected: number = this.panelHeightPx;
      if (heightVp < this.panelHeight) {
        corrected = Math.round(this.panelHeightPx * (this.panelHeight / heightVp));
      }
      console.info(`${TAG} calibrating resize: ${this.panelHeightPx} -> ${corrected}`);
      this.resizeWithRetry(this.panelWidthPx, corrected, 1);
    }
  }

  private initWindow(): void {
    if (!this.context) {
      console.error(`${TAG} initWindow: no context`);
      return;
    }
    this.applyLayout();
    const panelInfo: inputMethodEngine.PanelInfo = {
      type: inputMethodEngine.PanelType.SOFT_KEYBOARD,
      flag: inputMethodEngine.PanelFlag.FLG_FIXED
    };
    inputMethodEngine.getInputMethodAbility().createPanel(this.context, panelInfo)
      .then((panel: inputMethodEngine.Panel) => {
        console.info(`${TAG} createPanel ok`);
        this.panel = panel;
        console.info(`${TAG} setUiContent start`);
        return panel.setUiContent('inputmethod/pages/KeyboardIndex').then(() => {
          console.info(`${TAG} setUiContent ok`);
        });
      })
      .then(() => {
        if (this.panel) {
          const kb: inputMethodEngine.Panel = this.panel;
          // the panel window only becomes resizable once it exists; the system
          // may also consider a freshly created panel "already shown", so hide
          // it first, size it, and let the system show it on demand
          kb.on('show', () => {
            console.info(`${TAG} panel show event`);
            this.panelShown = true;
            this.calibAttempts = 0;
            this.resizeWithRetry(this.panelWidthPx, this.panelHeightPx, 1);
          });
          kb.on('hide', () => {
            console.info(`${TAG} panel hide event`);
            this.panelShown = false;
            if (PHYSICAL_KB_PIN_ENABLED && this.physicalKbActive && this.inputClient) {
              // editor still focused while a shared keyboard is attached: the
              // user may have no pointer to bring the keyboard back — do it
              setTimeout(() => {
                this.ensureShown();
              }, 600);
            }
          });
          console.info(`${TAG} panel initial hide`);
          return this.panel.hide().then(() => {
            console.info(`${TAG} panel hidden, resizing`);
            return this.resizeWithRetry(this.panelWidthPx, this.panelHeightPx, 1);
          }).catch((err: BusinessError) => {
            console.error(`${TAG} panel hide failed: code ${err.code}`);
            return this.resizeWithRetry(this.panelWidthPx, this.panelHeightPx, 1);
          });
        }
        return Promise.resolve();
      })
      .catch((err: BusinessError) => {
        console.error(`${TAG} initWindow failed: code ${err.code} msg ${err.message}`);
      });
  }

  /**
   * resize() can hit a 12800008 IMS race right after createPanel; retry a few times.
   */
  private resizeWithRetry(width: number, height: number, attempt: number): Promise<void> {
    if (!this.panel) {
      return Promise.resolve();
    }
    return this.panel.resize(width, height).then(() => {
      console.info(`${TAG} resize ok (attempt ${attempt})`);
    }).catch((err: BusinessError) => {
      console.error(`${TAG} resize attempt ${attempt} failed: code ${err.code}`);
      if (attempt < 6) {
        return new Promise<void>((resolve: (v: void) => void) => {
          setTimeout(resolve, 300);
        }).then(() => this.resizeWithRetry(width, height, attempt + 1));
      }
      console.error(`${TAG} resize giving up`);
      return Promise.resolve();
    });
  }

  private registerListener(): void {
    const ability = inputMethodEngine.getInputMethodAbility();
    ability.on('inputStart', (kbController: inputMethodEngine.KeyboardController,
      inputClient: inputMethodEngine.InputClient) => {
      console.info(`${TAG} inputStart`);
      this.kbController = kbController;
      this.inputClient = inputClient;
      this.resetComposition();
    });
    ability.on('inputStop', () => {
      console.info(`${TAG} inputStop`);
      this.resetComposition();
    });
    display.on('change', () => {
      this.applyLayout();
      if (this.panel) {
        this.panel.resize(this.panelWidthPx, this.panelHeightPx).catch((err: BusinessError) => {
          console.error(`${TAG} resizePanel: ${err.code} ${err.message}`);
        });
      }
      this.notifyUi();
    });
  }

  /**
   * Physical keyboard policy: an external keyboard attaching collapses the
   * soft panel to the candidate bar; detaching restores the full keyboard.
   * inputDevice change events need no permission; getKeyboardTypeSync tells
   * real alphabetic/numeric keyboards apart from virtual inputs.
   */
  private registerDeviceListener(): void {
    inputDevice.on('change', (d: inputDevice.DeviceListener) => {
      let kbType: number = -1;
      try {
        kbType = inputDevice.getKeyboardTypeSync(d.deviceId);
      } catch (e) {
        const be = e as BusinessError;
        console.warn(`${TAG} device ${d.deviceId} kb type unavailable: ${be.code}`);
        return;
      }
      const physical: boolean = kbType === inputDevice.KeyboardType.ALPHABETIC_KEYBOARD
        || kbType === inputDevice.KeyboardType.DIGITAL_KEYBOARD;
      console.info(`${TAG} device ${d.type} id=${d.deviceId} kbType=${kbType} physical=${physical}`);
      if (!physical) {
        return;
      }
      if (d.type === 'add') {
        this.physicalKbActive = true;
        this.kbExpanded = false;
        console.info(`${TAG} physical keyboard attached: collapsing to candidate bar`);
        this.applyPanelSize();
      } else {
        this.scanPhysicalKeyboard().then((still: boolean) => {
          this.physicalKbActive = still;
          this.kbExpanded = false;
          this.applyPanelSize();
        });
      }
    });
  }

  private scanPhysicalKeyboard(): Promise<boolean> {
    return inputDevice.getDeviceList().then((ids: number[]) => {
      let count: number = 0;
      for (let i = 0; i < ids.length; i++) {
        try {
          const kt: number = inputDevice.getKeyboardTypeSync(ids[i]);
          if (kt === inputDevice.KeyboardType.ALPHABETIC_KEYBOARD
            || kt === inputDevice.KeyboardType.DIGITAL_KEYBOARD) {
            count++;
          }
        } catch (e) {
          // device vanished between listing and query
        }
      }
      console.info(`${TAG} scanPhysicalKeyboard: ${count} physical keyboard(s)`);
      return count > 0;
    }).catch((err: BusinessError) => {
      console.error(`${TAG} getDeviceList failed: ${err.code}`);
      return false;
    });
  }

  private ensureShown(): void {
    const panel = this.panel;
    if (!panel || this.panelShown || !this.inputClient) {
      return;
    }
    panel.show().then(() => {
      console.info(`${TAG} soft panel re-shown for shared keyboard`);
    }).catch((err: BusinessError) => {
      console.error(`${TAG} re-show failed: ${err.code}`);
    });
  }

  public setUiListener(listener: UiListener | undefined): void {
    this.uiListener = listener;
    if (listener) {
      listener(this.composition, this.candidates, this.predicting, this.shiftOn, this.rowHeight,
        this.isCollapsed(), this.physicalKbActive, this.physicalPinyin, this.selCand);
    }
  }

  private notifyUi(): void {
    if (this.uiListener) {
      this.uiListener(this.composition, this.candidates, this.predicting, this.shiftOn, this.rowHeight,
        this.isCollapsed(), this.physicalKbActive, this.physicalPinyin, this.selCand);
    }
  }

  private resetComposition(): void {
    this.composition = '';
    this.baseCands = [];
    this.candidates = [];
    this.predicting = false;
    this.shiftOn = false;
    this.selCand = -1;
    this.notifyUi();
  }

  /** The typed letters themselves, offered as the first (English) candidate. */
  private rawCand(): Cand {
    const cand = new Cand();
    cand.isRaw = true;
    if (this.shiftOn && this.composition.length > 0) {
      cand.text = this.composition.charAt(0).toUpperCase() + this.composition.substring(1);
    } else {
      cand.text = this.composition;
    }
    return cand;
  }

  private rebuildComposing(): void {
    this.candidates = [];
    if (this.composition.length === 0) {
      return;
    }
    this.candidates.push(this.rawCand());
    for (const cand of this.baseCands) {
      this.candidates.push(cand);
    }
  }

  /**
   * A letter key was pressed. In EN mode (漢/EN toggle) letters commit
   * straight to the editor as typed English; Shift provides one capital.
   * In 漢 mode the letter extends the pinyin composition.
   */
  public onChar(ch: string): void {
    if (!this.physicalPinyin) {
      this.commitText(this.shiftOn ? ch.toUpperCase() : ch);
      return;
    }
    this.predicting = false;
    this.selCand = -1;
    this.composition += ch;
    const result: LookupResult = dictEngine.lookup(this.composition);
    this.baseCands = result.exact.concat(result.suggest);
    this.rebuildComposing();
    this.notifyUi();
  }

  public onNumeric(ch: string): void {
    this.commitText(ch);
  }

  public onShift(): void {
    this.shiftOn = !this.shiftOn;
    if (this.composition.length > 0 && !this.predicting) {
      this.rebuildComposing();
    }
    this.notifyUi();
  }

  /** Space: commit the first dictionary candidate, else the raw code, else a space. */
  public onSpace(): void {
    if (this.composition.length > 0) {
      if (this.baseCands.length > 0) {
        this.commitText(this.baseCands[0].text);
      } else {
        this.commitText(this.rawCand().text);
      }
      return;
    }
    if (this.predicting && this.candidates.length > 0) {
      this.commitText(this.candidates[0].text);
      return;
    }
    this.commitText(' ');
  }

  /**
   * Enter: commit what is typed as plain letters; with nothing composing,
   * honour the editor's declared key action. Single-line fields (search,
   * chat-send, next-field) reject an inserted '\n' entirely, so they must
   * get sendKeyFunction instead (ArkUI EnterKeyType: Go=2..Done=6; 0/1 =
   * plain newline / none, where inserting '\n' still wins if accepted).
   * Shift+Enter skips all that and asks for a literal line break.
   */
  public onEnter(shiftHeld: boolean = false): void {
    if (this.composition.length > 0) {
      this.commitText(this.rawCand().text);
      return;
    }
    if (shiftHeld) {
      this.commitText('\n');
      return;
    }
    const client = this.inputClient;
    if (!client) {
      return;
    }
    client.getEditorAttribute().then((attr: inputMethodEngine.EditorAttribute) => {
      const t: number = attr.enterKeyType;
      console.info(`${TAG} onEnter enterKeyType=${t}`);
      if (t >= 2) {
        client.sendKeyFunction(t).then((ok: boolean) => {
          if (!ok) {
            client.insertText('\n');
          }
        }).catch((err: BusinessError) => {
          console.error(`${TAG} sendKeyFunction: ${err.code}`);
          client.insertText('\n');
        });
      } else {
        client.insertText('\n').then((done: boolean) => {
          if (!done) {
            client.sendKeyFunction(t);
          }
        }).catch((err: BusinessError) => {
          console.error(`${TAG} insertText: ${err.code}`);
          client.sendKeyFunction(t);
        });
      }
    }).catch((err: BusinessError) => {
      console.error(`${TAG} getEditorAttribute: ${err.code}`);
      client.insertText('\n');
    });
  }

  /**
   * Backspace: shorten the composition while typing; otherwise always delete
   * in the client (and drop any related-word suggestions).
   */
  public onBackspace(): void {
    console.info(`${TAG} onBackspace comp=${this.composition} predicting=${this.predicting} hasClient=${this.inputClient !== undefined}`);
    this.selCand = -1;
    if (this.composition.length > 0) {
      this.composition = this.composition.substring(0, this.composition.length - 1);
      if (this.composition.length === 0) {
        this.baseCands = [];
        this.candidates = [];
        this.predicting = false;
      } else {
        const result: LookupResult = dictEngine.lookup(this.composition);
        this.baseCands = result.exact.concat(result.suggest);
        this.rebuildComposing();
      }
      this.notifyUi();
      return;
    }
    this.predicting = false;
    this.candidates = [];
    const client = this.inputClient;
    if (client) {
      try {
        const idx: number = client.getTextIndexAtCursorSync();
        const bwd: string = client.getBackwardSync(20);
        const fwd: string = client.getForwardSync(10000);
        console.info(`${TAG} probe idx=${idx} bwd="${bwd}" fwdLen=${fwd.length} fwd="${fwd.substring(0, 12)}"`);
        if (bwd.length > 0) {
          client.deleteBackwardSync(1);
          console.info(`${TAG} deleteBackwardSync ok`);
        } else if (fwd.length > 0) {
          // this editor reports the cursor at index 0 while text exists after
          // it, so delete-before-cursor is a silent no-op; delete the LAST
          // character by selecting it and sending CUT instead
          const range: inputMethodEngine.Range = { start: fwd.length - 1, end: fwd.length };
          client.selectByRangeSync(range);
          client.sendExtendAction(inputMethodEngine.ExtendAction.CUT).then(() => {
            console.info(`${TAG} selection CUT sent (idx ${fwd.length - 1})`);
          }).catch((err: BusinessError) => {
            console.error(`${TAG} CUT: ${err.code} ${err.message}`);
          });
        } else {
          client.deleteBackward(1).then((done: boolean) => {
            console.info(`${TAG} deleteBackward -> ${done} (empty-editor path)`);
          }).catch((err: BusinessError) => {
            console.error(`${TAG} deleteBackward: ${err.code} ${err.message}`);
          });
        }
      } catch (e) {
        const be = e as BusinessError;
        console.error(`${TAG} sync probe failed ${be.code} ${be.message}; async fallback`);
        client.deleteBackward(1).then((done: boolean) => {
          console.info(`${TAG} deleteBackward -> ${done}`);
        }).catch((err: BusinessError) => {
          console.error(`${TAG} deleteBackward: ${err.code} ${err.message}`);
        });
      }
    } else {
      console.warn(`${TAG} backspace with no inputClient`);
    }
    this.notifyUi();
  }

  public chooseCandidate(index: number): void {
    if (index >= 0 && index < this.candidates.length) {
      this.commitText(this.candidates[index].text);
    }
  }

  /** Punctuation: flush the pending composition first, then type the symbol. */
  public onPunctuation(ch: string): void {
    if (this.composition.length > 0) {
      this.commitText(this.rawCand().text);
    }
    this.commitText(this.shiftOn ? MixedController.flipPunct(ch) : ch);
  }

  /** Shift on a punctuation key swaps half <-> full width (. 。 , ，). */
  private static flipPunct(ch: string): string {
    if (ch === '.') {
      return '。';
    }
    if (ch === '。') {
      return '.';
    }
    if (ch === ',') {
      return '，';
    }
    if (ch === '，') {
      return ',';
    }
    return ch;
  }

  private commitText(text: string): void {
    console.info(`${TAG} commitText "${text}" hasClient=${this.inputClient !== undefined}`);
    if (this.inputClient) {
      this.inputClient.insertText(text).then((done: boolean) => {
        if (!done) {
          console.warn(`${TAG} insertText returned false`);
        }
      }).catch((err: BusinessError) => {
        console.error(`${TAG} insertText: ${err.code} ${err.message}`);
      });
    }
    const committed: string = text;
    this.composition = '';
    this.baseCands = [];
    this.shiftOn = false;
    this.selCand = -1;
    // related-word prediction (phrase_N.ms2) for the word just committed
    const predictions: Cand[] = dictEngine.predict(committed);
    if (predictions.length > 0) {
      this.predicting = true;
      this.candidates = predictions;
    } else {
      this.predicting = false;
      this.candidates = [];
    }
    this.notifyUi();
  }
}

export const mixedController: MixedController = new MixedController();
