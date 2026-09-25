import { inputMethodEngine, InputMethodExtensionContext } from '@kit.IMEKit';
import { display } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import inputDevice from '@ohos.multimodalInput.inputDevice';
import { KeyEvent as PhysKeyEvent } from '@ohos.multimodalInput.keyEvent';
import { Cand, dictEngine, LookupResult } from './DictEngine';

/** Screen position (px) for the floating bar window. */
export interface BarRect {
  left: number;
  top: number;
}

export type UiListener =
  (composition: string, candidates: Cand[], predicting: boolean, shift: boolean, rowHeight: number,
    expanded: boolean, collapsed: boolean, physicalMode: boolean, pinyinOn: boolean, sel: number) => void;

const TAG: string = 'MixedController';
// fixed chrome above/below the key rows: candidate bar + row gaps + padding
// Jyutping sizing model (adopted 2026-09-24 from yuetyam/jyutping-harmony,
// CC0 — user prefers their absolute sizes; our fold/rotate refresh engine
// fixes their stale-sizing weakness):
//   key(pt) = phone-landscape ? 36 : min(53 + floor((widthPt - 300) / 20), 58)
//   panel   = 56 (slim toolbar incl. candidate bar) + key * 4
// widthPt/heightPt are the CURRENT-orientation dimensions in points; a phone
// is "landscape" when width > height and the short side < 500pt.
const JYUT_TOOLBAR_PT: number = 56;
const JYUT_KEY_LANDSCAPE_PHONE_PT: number = 36;
const JYUT_KEY_PORTRAIT_BASE_PT: number = 53;
const JYUT_KEY_PORTRAIT_MAX_PT: number = 58;
const MIN_ROW_VP: number = 24;
const MAX_ROW_VP: number = JYUT_KEY_PORTRAIT_MAX_PT;
// tablet / unfolded-foldable class: short axis at least this many vp gets the
// wider horizontal margins (styling only — vertical sizing is Jyutping's now)
const EXPANDED_MIN_SHORT_AXIS_VP: number = 550;
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
  // build identifier logged in onCreate: hilog "build <stamp>" proves which
  // bundle the LIVE service actually runs (install -r does not always
  // restart a running input-method service)
  static readonly STAMP: string = 'strip-above6 2026-09-25';
  private context: InputMethodExtensionContext | undefined;
  private panel: inputMethodEngine.Panel | undefined;
  private kbController: inputMethodEngine.KeyboardController | undefined;
  private inputClient: inputMethodEngine.InputClient | undefined;
  private uiListener: UiListener | undefined;
  private panelWidth: number = 0;
  private panelHeight: number = 0;
  private panelWidthPx: number = 0;
  private panelHeightPx: number = 0;
  // full-screen panel width (px) for the expanded keyboard
  private fullWidthPx: number = 0;
  private densityPx: number = 1;
  // bottom navigation-indicator / dock avoid-area height (vp) reported by the
  // page; the panel window is grown by this much and the page renders a
  // transparent spacer of the same height so the keys sit ABOVE the dock
  // instead of covering it. 0 on devices whose panel already avoids it.
  private bottomInset: number = 0;
  private rowHeight: number = 46;
  private measuredHeight: number = 0;
  private calibAttempts: number = 0;
  // panel width in vp as actually rendered, reported by the page. The display
  // object's width/height do not reliably swap on rotation on every build, so
  // this measured value is the source of truth for which axis we currently
  // span and how wide to resize the panel.
  private lastAreaW: number = 0;
  private relayoutTimer: number = -1;
  private lastMismatchSig: string = '';
  private resizeGiveups: number = 0;
  private lastKeyLogAt: number = 0;

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
  // active "raw digit" prediction round: the digit already committed to the
  // editor whose dictionary extensions are offered (e.g. after 8, the dict
  // suggests "8," / "8."). Accepting one must REPLACE that digit (delete it
  // first), not append — typing 8 and accepting "8," yields "8," not "88,".
  // Empty = no such round.
  private rawRound: string = '';
  // true while commitRawChoice commits the replacement text, so the digit
  // branch does not immediately re-arm the round it is trying to close
  private roundCommitting: boolean = false;

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
    this.rawRound = '';
    if (!this.physicalPinyin) {
      // entering EN always clears composing AND any lingering related-word
      // suggestions from the last 漢 commit — stale predictions would make
      // the first Space commit one of them
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
    if (ev.action !== KEY_ACTION_PRESS) {
      return false;
    }
    const code: number = ev.key.code as number;
    // burst-gated diagnostics: proves whether physical keys reach the IME at
    // all (e.g. PC-compat container apps may bypass the keyboard delegate)
    const now: number = Date.now();
    if (now - this.lastKeyLogAt > 2000) {
      this.lastKeyLogAt = now;
      console.info(`${TAG} physKey code=${code} ctrl=${ev.ctrlKey} pinyin=${this.physicalPinyin} hasClient=${this.inputClient !== undefined} physicalKb=${this.physicalKbActive}`);
    }
    if (!this.inputClient) {
      return false;
    }
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
        this.commitText(this.candidates[this.selCand].text, true);
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
        this.commitText(this.candidates[this.selCand].text, true);
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

  /** The extension context that owns the panel window (for window lookups). */
  public getExtensionContext(): InputMethodExtensionContext | undefined {
    return this.context;
  }

  public onCreate(context: InputMethodExtensionContext): void {
    console.info(`${TAG} onCreate enter — build ${MixedController.STAMP}`);
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
    // pre-warm the ASCII phrase bucket (digits' home) off the hot path so
    // the first typed digit never pays the ~0.6MB sync parse
    setTimeout(() => {
      const t0 = Date.now();
      dictEngine.predict('0');
      console.info(`${TAG} phrase bucket prewarmed in ${Date.now() - t0}ms`);
    }, 4000);
  }

  public onDestroy(): void {
    if (this.relayoutTimer !== -1) {
      clearTimeout(this.relayoutTimer);
      this.relayoutTimer = -1;
    }
    display.off('change');
    display.off('foldStatusChange');
    display.off('foldDisplayModeChange');
    if (this.panel) {
      inputMethodEngine.getInputMethodAbility().destroyPanel(this.panel).catch((err: BusinessError) => {
        console.error(`${TAG} destroyPanel: ${err.code} ${err.message}`);
      });
      this.panel = undefined;
    }
  }

  /**
   * Derive the panel geometry from the LIVE display every time it runs, so
   * any device / orientation / fold state lays out from fractions of the real
   * screen instead of per-device constants. Orientation is resolved from the
   * panel's own measured width when the page has reported one (display
   * width/height do not reliably swap on rotation).
   */
  private applyLayout(): void {
    const dis = display.getDefaultDisplaySync();
    const density: number = dis.densityPixels > 0 ? dis.densityPixels : 1;
    const longPx: number = Math.max(dis.width, dis.height);
    const shortPx: number = Math.min(dis.width, dis.height);
    const longAxisVp: number = Math.floor(longPx / density);
    const shortAxisVp: number = Math.floor(shortPx / density);
    // Rotation is the authoritative orientation signal. Do NOT decide from
    // the measured panel width alone: it goes stale across a fold (a
    // trifold-landscape width numerically matches the folded display's long
    // axis, which misdetected landscape and demanded an impossible
    // 2232px-wide resize that failed 12800008 forever).
    const isLandscape: boolean = dis.rotation === 1 || dis.rotation === 3;
    // Jyutping sizing: key heights in POINTS from the current-orientation
    // width — 53 + 1 per extra 20pt of width over 300, capped at 58 — with a
    // flat 36pt key for phone-landscape screens. The slim 56pt toolbar is the
    // only non-key furniture, so panel = 56 + 4 * key.
    const widthPt: number = (isLandscape ? longPx : shortPx) / density;
    const heightPt: number = (isLandscape ? shortPx : longPx) / density;
    const isPhoneLandscape: boolean = widthPt > heightPt && heightPt < 500;
    let keyPt: number = isPhoneLandscape
      ? JYUT_KEY_LANDSCAPE_PHONE_PT
      : Math.min(JYUT_KEY_PORTRAIT_BASE_PT + Math.floor((widthPt - 300) / 20), JYUT_KEY_PORTRAIT_MAX_PT);
    if (keyPt < MIN_ROW_VP) {
      keyPt = MIN_ROW_VP;
    }
    // expandedScreen now only drives horizontal margins/styling in the page
    this.expandedScreen = shortAxisVp >= EXPANDED_MIN_SHORT_AXIS_VP;
    this.rowHeight = Math.floor(keyPt);
    // the measured width is only a refinement: trust it when it agrees with
    // the rotation-implied axis (within 5%), otherwise fall back to the axis
    const impliedWpx: number = isLandscape ? longPx : shortPx;
    this.panelWidth = this.lastAreaW > 0
      && Math.abs(this.lastAreaW * density - impliedWpx) <= impliedWpx * 0.05
      ? this.lastAreaW
      : impliedWpx / density;
    this.basePanelHeight = JYUT_TOOLBAR_PT + this.rowHeight * 4;
    // resize() is applied in PHYSICAL pixels, not vp: a resize(350, 270) for
    // 270vp produced a 270-px window (94vp) on a density-2.875 screen.
    this.densityPx = density;
    this.panelWidthPx = Math.round(this.panelWidth * density);
    this.fullWidthPx = this.panelWidthPx;
    this.applyPanelSize();
    console.info(`${TAG} applyLayout: ${dis.width}x${dis.height} rot${dis.rotation} d${density} ${isLandscape ? 'landscape' : 'portrait'} ${isPhoneLandscape ? 'phone-landscape ' : ''}width ${Math.floor(widthPt)}pt row ${this.rowHeight}pt panel ${this.panelWidth}x${this.panelHeight}vp (${this.panelWidthPx}x${this.panelHeightPx}px)`);
  }

  /**
   * Effective window size: the full keyboard, or the slim COLLAPSED_VP
   * candidate bar while a physical keyboard is attached.
   */
  private applyPanelSize(): void {
    // One system-pinned FLG_FIXED panel for both modes: the full keyboard
    // fills it, and the physical-keyboard candidate bar is a slim strip drawn
    // inside a transparent full-width window. The WM silently IGNORES
    // moveWindowTo/startMoving on IME panels (verified on the 2-in-1: the
    // call resolves but the window rect never changes), so the window itself
    // is never moved; the strip slides inside it instead.
    // collapsed = slim full-width band; the page draws the visible candidate
    // strip inside it and (if the surface allows transparency) only the strip
    // is visible. FLG_FIXED both modes: panel moves are system-blocked
    // (moveWindowTo ignored, startMoving hides the panel), so the window
    // never moves and never needs the floating flag.
    this.panelWidthPx = this.fullWidthPx;
    this.panelWidth = this.fullWidthPx / this.densityPx;
    // collapsed: strip height + the taskbar/dock inset, so the visible strip
    // sits ABOVE the taskbar and only a transparent, touch-passing zone
    // covers the taskbar itself
    this.panelHeight = this.isCollapsed()
      ? COLLAPSED_VP + this.bottomInset
      : this.basePanelHeight + this.bottomInset;
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
    this.applyLayout();
  }

  /**
   * Bottom dock / navigation-indicator height (vp) measured by the page. The
   * panel window is grown by this amount and the page paints a transparent
   * spacer of the same height at its base, so the keyboard/candidate bar
   * renders above the dock rather than on top of it.
   */
  public setBottomInset(vp: number): void {
    const next: number = vp > 0 ? vp : 0;
    if (Math.abs(next - this.bottomInset) < 1) {
      return;
    }
    console.info(`${TAG} bottomInset ${this.bottomInset} -> ${next} vp`);
    this.bottomInset = next;
    this.calibAttempts = 0;
    this.applyLayout();
  }

  /**
   * The keyboard page reports its real rendered size here (vp). This is the
   * self-healing feedback loop: if the actual window no longer matches the
   * metrics we laid out with — exactly what a rotation or fold change looks
   * like when the display events fire late or not at all — we recompute the
   * layout from live values. calibAttempts is only reset once the reported
   * area settles on our expected metrics, so the loop is bounded.
   */
  public onContentArea(widthVp: number, heightVp: number): void {
    if (heightVp <= 0 || widthVp <= 0) {
      return;
    }
    const widthChanged: boolean = Math.abs(widthVp - this.lastAreaW) > 2;
    this.lastAreaW = widthVp;
    const chrome: number = JYUT_TOOLBAR_PT;
    const minRow: number = MIN_ROW_VP;
    const maxRow: number = MAX_ROW_VP;
    if (this.isCollapsed()) {
      // collapsed bar: fixed height, but a rotation still swaps the width
      if (widthChanged && this.calibAttempts < 3 && Math.abs(widthVp - this.panelWidth) > 12) {
        this.calibAttempts++;
        this.applyLayout();
      }
      return;
    }
    this.measuredHeight = heightVp;
    // fit rows to the window the system ACTUALLY granted, on every device
    // class: when a fold/rotate race or a system clamp leaves the window
    // smaller (or larger) than requested, the content adapts instead of
    // overflowing (which clipped the candidate bar at the top). The window was
    // grown by bottomInset for the dock spacer, so subtract it before fitting.
    let rowH: number = Math.floor((heightVp - chrome - this.bottomInset) / 4);
    if (rowH < minRow) {
      rowH = minRow;
    } else if (rowH > maxRow) {
      rowH = maxRow;
    }
    if (rowH !== this.rowHeight) {
      this.rowHeight = rowH;
    }
    const mismatchSig: string = `${Math.round(widthVp)}x${Math.round(heightVp)}->${Math.round(this.panelWidth)}x${Math.round(this.panelHeight)}`;
    const settled: boolean = Math.abs(widthVp - this.panelWidth) <= 12
      && Math.abs(heightVp - this.panelHeight) <= 8;
    if (settled) {
      this.calibAttempts = 0;
      this.lastMismatchSig = '';
    } else if (this.calibAttempts < 3) {
      this.calibAttempts++;
      console.info(`${TAG} onContentArea mismatch ${widthVp}x${heightVp} vs ${this.panelWidth}x${this.panelHeight}vp: relayout (${this.calibAttempts})`);
      this.applyLayout();
      this.notifyUi();
      return;
    } else if (mismatchSig !== this.lastMismatchSig) {
      // geometry changed AGAIN after the budget ran out (next stage of a
      // fold animation, density change): take one more run at it
      this.lastMismatchSig = mismatchSig;
      this.calibAttempts = 1;
      this.applyLayout();
      this.notifyUi();
      return;
    }
    console.info(`${TAG} onContentArea measured ${widthVp}x${heightVp}vp row ${this.rowHeight}vp`);
    this.notifyUi();
    if (this.panel && this.calibAttempts < 2 && heightVp < this.panelHeight - 8) {
      // the system clamped the window smaller than requested: re-resize once
      // scaled by the wanted/got ratio (covers unit or clamp differences)
      this.calibAttempts++;
      const corrected: number = Math.round(this.panelHeightPx * (this.panelHeight / heightVp));
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
    this.setupPanel();
  }

  /**
   * Create the panel with the window semantics the current mode needs.
   * FLG_FIXED: the system pins the full keyboard to the screen bottom.
   * FLG_FLOATING: the slim candidate bar — the WM honours its RESIZE (1/3
   * screen width works) but pins it top-left and ignores moveWindowTo, so
   * the page re-creates nothing; the bar's x-position is instead chosen by
   * re-creating the panel is NOT needed — the page now offsets the CONTENT
   * inside the transparent full-height strip... (simplified: bar drawn
   * top-right by the page inside the floating window).
   */
  private setupPanel(): void {
    if (!this.context) {
      return;
    }
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
            // re-derive from live metrics: rotation/fold may have happened
            // while the panel was hidden and no area report will correct us
            this.applyLayout();
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
          return kb.hide().then(() => {
            console.info(`${TAG} panel hidden, resizing`);
            return this.resizeWithRetry(this.panelWidthPx, this.panelHeightPx, 1);
          }).then(() => {
            if (this.inputClient) {
              // mid-session panel re-creation: bring the keyboard back
              kb.show().catch((err: BusinessError) => {
                console.error(`${TAG} re-show failed: ${err.code}`);
              });
            }
          }).catch((err: BusinessError) => {
            console.error(`${TAG} panel hide failed: code ${err.code}`);
            return this.resizeWithRetry(this.panelWidthPx, this.panelHeightPx, 1);
          });
        }
        return Promise.resolve();
      })
      .catch((err: BusinessError) => {
        console.error(`${TAG} setupPanel failed: code ${err.code} msg ${err.message}`);
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
      this.resizeGiveups = 0;
      console.info(`${TAG} resize ok (attempt ${attempt})`);
    }).catch((err: BusinessError) => {
      console.error(`${TAG} resize attempt ${attempt} failed: code ${err.code}`);
      if (attempt < 6) {
        return new Promise<void>((resolve: (v: void) => void) => {
          setTimeout(resolve, 300);
        }).then(() => this.resizeWithRetry(width, height, attempt + 1));
      }
      console.error(`${TAG} resize giving up`);
      this.recoverFromResizeFailure();
      return Promise.resolve();
    });
  }

  /**
   * After a resize exhausted its retries, self-heal: re-derive the layout
   * with a growing backoff. Valid arguments should never land here; this
   * covers system races. Bounded at 3 rounds — beyond that, wait for the
   * next real geometry event (which resets the counter).
   */
  private recoverFromResizeFailure(): void {
    if (this.resizeGiveups >= 3) {
      return;
    }
    this.resizeGiveups++;
    const delay: number = 1500 * this.resizeGiveups;
    setTimeout(() => {
      console.info(`${TAG} resize-failure recovery relayout (${this.resizeGiveups})`);
      this.calibAttempts = 0;
      this.applyLayout();
      this.notifyUi();
    }, delay);
  }

  private registerListener(): void {
    const ability = inputMethodEngine.getInputMethodAbility();
    ability.on('inputStart', (kbController: inputMethodEngine.KeyboardController,
      inputClient: inputMethodEngine.InputClient) => {
      console.info(`${TAG} inputStart`);
      this.kbController = kbController;
      this.inputClient = inputClient;
      this.resetComposition();
      // cheap safety net: geometry changes that happened while no editor was
      // focused (and possibly while the panel was hidden) get picked up here
      this.scheduleRelayout();
    });
    ability.on('inputStop', () => {
      console.info(`${TAG} inputStop`);
      this.resetComposition();
    });
    // any display geometry change funnels into ONE debounced relayout;
    // 'change' alone misses fold transitions and rotations on some builds
    display.on('change', () => this.scheduleRelayout());
    display.on('foldStatusChange', () => this.scheduleRelayout());
    display.on('foldDisplayModeChange', () => this.scheduleRelayout());
  }

  /** Coalesce bursty display events into a single relayout pass. */
  private scheduleRelayout(): void {
    if (this.relayoutTimer !== -1) {
      return;
    }
    this.relayoutTimer = setTimeout(() => {
      this.relayoutTimer = -1;
      // a genuine geometry event grants a fresh correction budget: the
      // transitional (mid-fold / mid-rotate) area reports that follow must
      // not permanently exhaust it
      this.calibAttempts = 0;
      this.resizeGiveups = 0;
      this.applyLayout();
      this.notifyUi();
    }, 300);
  }

  /**
   * Physical keyboard policy: an external keyboard attaching collapses the
   * soft panel to the candidate bar; detaching restores the full keyboard.
   * inputDevice change events need no permission; getKeyboardTypeSync tells
   * real alphabetic/numeric keyboards apart from virtual inputs.
   */
  /**
   * True only for real external keyboards. keyboardType alone is not enough:
   * Bluetooth peripherals like a paired watch expose a HID "consumer control"
   * interface that reports ALPHABETIC_KEYBOARD, which wrongly collapsed the
   * panel to the candidate bar whenever the watch was connected. A physical
   * keyboard additionally advertises the 'keyboard' input source.
   */
  private isRealKeyboard(deviceId: number): boolean {
    try {
      const dev: inputDevice.InputDeviceData = inputDevice.getDeviceInfoSync(deviceId);
      const kt: number = inputDevice.getKeyboardTypeSync(deviceId);
      const hasKbSource: boolean = dev.sources !== undefined && dev.sources.indexOf('keyboard') >= 0;
      // "Consumer Control" is the standard HID top-level-collection name for
      // media-control interfaces on watches/headsets — such interfaces can
      // claim the keyboard source and an alphabetic type, so exclude them
      const companion: boolean = /consumer control/i.test(dev.name);
      console.info(`${TAG} device ${deviceId} name="${dev.name}" kbType=${kt} sources=${JSON.stringify(dev.sources)} virtual=${dev.isVirtual}`);
      return !dev.isVirtual && !companion && hasKbSource
        && (kt === inputDevice.KeyboardType.ALPHABETIC_KEYBOARD
          || kt === inputDevice.KeyboardType.DIGITAL_KEYBOARD);
    } catch (e) {
      const be = e as BusinessError;
      console.warn(`${TAG} device ${deviceId} info unavailable: ${be.code}`);
      return false;
    }
  }

  private registerDeviceListener(): void {
    inputDevice.on('change', (d: inputDevice.DeviceListener) => {
      const physical: boolean = this.isRealKeyboard(d.deviceId);
      if (!physical) {
        return;
      }
      if (d.type === 'add') {
        this.physicalKbActive = true;
        this.kbExpanded = false;
        console.info(`${TAG} physical keyboard attached: collapsing to candidate bar`);
        this.applyLayout();
      } else {
        this.scanPhysicalKeyboard().then((still: boolean) => {
          this.physicalKbActive = still;
          this.kbExpanded = false;
          this.applyLayout();
        });
      }
    });
  }

  private scanPhysicalKeyboard(): Promise<boolean> {
    return inputDevice.getDeviceList().then((ids: number[]) => {
      let count: number = 0;
      for (let i = 0; i < ids.length; i++) {
        if (this.isRealKeyboard(ids[i])) {
          count++;
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
        this.expandedScreen, this.isCollapsed(), this.physicalKbActive, this.physicalPinyin, this.selCand);
    }
  }

  private notifyUi(): void {
    if (this.uiListener) {
      this.uiListener(this.composition, this.candidates, this.predicting, this.shiftOn, this.rowHeight,
        this.expandedScreen, this.isCollapsed(), this.physicalKbActive, this.physicalPinyin, this.selCand);
    }
  }

  private resetComposition(): void {
    this.composition = '';
    this.baseCands = [];
    this.candidates = [];
    this.predicting = false;
    this.shiftOn = false;
    this.selCand = -1;
    this.rawRound = '';
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

  /** Space: commit the first dictionary candidate, else the raw code, else a space.
   * In EN mode it is ALWAYS a plain space — the related-word rule below is a
   * Chinese-typing behavior and once inserted dictionary predictions like
   * "8," instead of the space (typing 8 then space produced "88,"). */
  public onSpace(): void {
    if (!this.physicalPinyin) {
      this.commitText(' ');
      return;
    }
    if (this.composition.length > 0) {
      if (this.baseCands.length > 0) {
        this.commitText(this.baseCands[0].text, true);
      } else {
        this.commitText(this.rawCand().text);
      }
      return;
    }
    if (this.predicting && this.candidates.length > 0) {
      if (this.rawRound !== '') {
        this.commitRawChoice(this.candidates[0].text);
      } else {
        this.commitText(this.candidates[0].text, true);
      }
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
    this.rawRound = '';
    this.deleteBeforeCursor(1);
    this.notifyUi();
  }

  /**
   * Deletes the `length` characters BEFORE the caret — the backspace
   * direction. The SDK's deleteBackward/deleteForward naming is inverted
   * relative to intuition: Jyutping (yuetyam/jyutping-harmony, shipping on
   * AppGallery) maps its backspace KEY to deleteForward and keeps
   * deleteBackward for right-side delete — and calling deleteBackward here
   * visibly deleted the NEXT character (container apps, EasyAbroad). The
   * mapping lives in this one helper so it can never drift between paths.
   */
  private deleteBeforeCursor(length: number): void {
    this.inputClient?.deleteForward(length).catch((err: BusinessError) => {
      console.error(`${TAG} deleteForward(backspace): ${err.code} ${err.message}`);
    });
  }

  public chooseCandidate(index: number): void {
    if (index >= 0 && index < this.candidates.length) {
      if (this.rawRound !== '') {
        this.commitRawChoice(this.candidates[index].text);
      } else {
        this.commitText(this.candidates[index].text, true);
      }
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

  private commitText(text: string, predictRelated: boolean = false): void {
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
    // related-word prediction (phrase_N.ms2) ONLY after committing a real
    // Chinese candidate (predictRelated). Raw output — punctuation, raw
    // English, plain spaces — never arms predictions. EXCEPTION (user
    // design): in 漢 mode a committed DIGIT opens a deliberate round — the
    // digit itself is the FIRST chip (one Space confirms what was typed),
    // followed by the dict's digit-string entries ("8," "8." …); accepting
    // one of those REPLACES the digit (see commitRawChoice), so 8 + "8,"
    // yields "8," not "88,".
    if (predictRelated && this.physicalPinyin) {
      const predictions: Cand[] = dictEngine.predict(committed);
      if (predictions.length > 0) {
        this.predicting = true;
        this.candidates = predictions;
      } else {
        this.predicting = false;
        this.candidates = [];
      }
      this.rawRound = '';
    } else if (this.physicalPinyin && !this.roundCommitting
      && committed.length === 1 && committed >= '0' && committed <= '9') {
      const digitSelf = new Cand();
      digitSelf.isRaw = true;
      digitSelf.text = committed;
      const seen: Set<string> = new Set<string>([committed]);
      const exts: Cand[] = [];
      for (const c of dictEngine.predict(committed)) {
        if (seen.has(c.text)) {
          continue;
        }
        seen.add(c.text);
        const one = new Cand();
        one.isRaw = false;
        one.text = c.text;
        exts.push(one);
      }
      if (exts.length > 0) {
        this.rawRound = committed;
        this.candidates = [digitSelf].concat(exts);
        this.predicting = true;
        console.info(`${TAG} digit round armed: ${committed} + ${exts.length} ext`);
      } else {
        // no dictionary extensions for this digit: no round at all, the next
        // Space is an ordinary space
        this.rawRound = '';
        this.predicting = false;
        this.candidates = [];
      }
    } else {
      this.rawRound = '';
      this.predicting = false;
      this.candidates = [];
    }
    this.notifyUi();
  }

  /**
   * Accept a digit-round chip. Confirm (chip == the typed digit): the digit
   * already sits in the editor — do NOTHING to the text, just close the
   * round. Replace (a longer entry like "8,"): delete the digit first
   * (async — the sync delete natively crashed the IME on some editors),
   * then insert; if the delete fails we keep the digit rather than append a
   * duplicate.
   */
  private commitRawChoice(text: string): void {
    const client = this.inputClient;
    const digit: string = this.rawRound;
    this.rawRound = '';
    if (text === digit) {
      this.predicting = false;
      this.candidates = [];
      this.notifyUi();
      return;
    }
    const closeRound = (): void => {
      this.predicting = false;
      this.candidates = [];
      this.roundCommitting = false;
      this.notifyUi();
    };
    const commitReplacement = (): void => {
      this.roundCommitting = true;
      this.commitText(text, false);
      this.roundCommitting = false;
    };
    if (client) {
      // same direction rule as deleteBeforeCursor: deleteForward removes the
      // text before the caret (Jyutping mapping) — the digit sits right
      // before the caret after being committed
      client.deleteForward(digit.length).then((done: boolean) => {
        if (done) {
          commitReplacement();
        } else {
          console.warn(`${TAG} raw-round delete refused; keeping "${digit}"`);
          closeRound();
        }
      }).catch((err: BusinessError) => {
        console.error(`${TAG} raw-round delete failed ${err.code}; keeping "${digit}"`);
        closeRound();
      });
    } else {
      commitReplacement();
    }
  }
}

export const mixedController: MixedController = new MixedController();
