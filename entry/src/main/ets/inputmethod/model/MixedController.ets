import { inputMethodEngine, InputMethodExtensionContext } from '@kit.IMEKit';
import { display } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import inputDevice from '@ohos.multimodalInput.inputDevice';
import { speechRecognizer } from '@kit.CoreSpeechKit';
import { audio } from '@kit.AudioKit';
import { Cand, dictEngine, LookupResult } from './DictEngine';

export type UiListener =
  (composition: string, candidates: Cand[], predicting: boolean, shift: boolean, rowHeight: number,
    voiceOn: boolean, voiceHint: string, collapsed: boolean, physicalMode: boolean) => void;

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
// Physical keyboards (MatePad Edge share, Bluetooth/folio): the full panel
// used to auto-hide on connect, which made the keyboard unrecoverable when
// the shared mouse pointer leaves the screen. Policy now: collapse to a slim
// candidate bar with a ^ restore arrow (tap ^ for the keys, ⌄ to collapse),
// and auto re-show if the bar ever gets hidden while an editor is attached.
const PHYSICAL_KB_PIN_ENABLED: boolean = true;
const COLLAPSED_VP: number = 60;

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

  // physical keyboard policy: pin the soft panel while a shared keyboard is attached
  private physicalKbActive: boolean = false;
  private kbExpanded: boolean = false;
  private basePanelHeight: number = 270;
  private panelShown: boolean = false;

  /** true = only the candidate bar should be shown (physical keyboard in use) */
  public isCollapsed(): boolean {
    return this.physicalKbActive && !this.kbExpanded;
  }

  // voice session (hold Space): on-device recognizer fed by AudioCapturer
  private voiceEngine: speechRecognizer.SpeechRecognitionEngine | undefined = undefined;
  private voiceCapturer: audio.AudioCapturer | undefined = undefined;
  private voiceSessionId: string = '';
  private voiceBuf: Uint8Array = new Uint8Array(0);
  private voiceText: string = '';
  private voiceOn: boolean = false;
  private voiceHint: string = '';

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
    let rowH: number;
    if (shortAxisVp >= EXPANDED_MIN_SHORT_AXIS_VP) {
      rowH = EXPANDED_ROW_VP;
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
    this.basePanelHeight = NON_ROW_VP + rowH * 4;
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
    let rowH: number = Math.floor((heightVp - NON_ROW_VP) / 4);
    if (rowH < MIN_ROW_VP) {
      rowH = MIN_ROW_VP;
    } else if (rowH > MAX_ROW_VP) {
      rowH = MAX_ROW_VP;
    }
    if (rowH !== this.rowHeight) {
      this.rowHeight = rowH;
    }
    console.info(`${TAG} onContentArea measured ${heightVp}vp row ${rowH}vp`);
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

  /**
   * Voice typing (#3): hold Space to dictate. CoreSpeechKit runs on-device
   * (online=1); AudioCapturer streams 16k mono S16 PCM in 1280-byte chunks.
   * Releasing Space finishes and inserts the recognized text.
   */
  public onVoiceStart(): void {
    if (this.voiceOn) {
      return;
    }
    this.voiceHint = '';
    this.voiceText = '';
    this.voiceBuf = new Uint8Array(0);
    if (this.composition.length > 0) {
      this.resetComposition();
    }
    this.voiceOn = true;
    this.notifyUi();
    this.startVoiceCapture();
  }

  public onVoiceStop(): void {
    if (!this.voiceOn) {
      return;
    }
    this.voiceOn = false;
    this.notifyUi();
    this.stopCapturer();
    try {
      this.voiceEngine?.finish(this.voiceSessionId);
    } catch (e) {
      const be = e as BusinessError;
      console.warn(`${TAG} voice finish: ${be.code}`);
    }
  }

  private startVoiceCapture(): void {
    const sid: string = `hmixed-${Date.now()}`;
    this.voiceSessionId = sid;
    let engineStep: Promise<void>;
    if (this.voiceEngine) {
      engineStep = Promise.resolve();
    } else {
      const ep: speechRecognizer.CreateEngineParams = { language: 'zh-CN', online: 1 };
      engineStep = speechRecognizer.createEngine(ep).then((engine: speechRecognizer.SpeechRecognitionEngine) => {
        this.voiceEngine = engine;
        const listener: speechRecognizer.RecognitionListener = {
          onStart: (s: string, m: string) => {
            console.info(`${TAG} voice onStart ${s}`);
          },
          onEvent: (s: string, code: number, m: string) => {
            console.info(`${TAG} voice onEvent ${code}`);
          },
          onResult: (s: string, r: speechRecognizer.SpeechRecognitionResult) => {
            console.info(`${TAG} voice result: ${r.result}`);
            if (r.result.length > 0) {
              this.voiceText = r.result;
            }
          },
          onComplete: (s: string, m: string) => {
            this.voiceComplete();
          },
          onError: (s: string, code: number, msg: string) => {
            console.error(`${TAG} voice onError ${code} ${msg}`);
            this.voiceFail(`語音識別失敗 ${code}`);
          }
        };
        engine.setListener(listener);
      });
    }
    engineStep.then(() => {
      const engine = this.voiceEngine;
      if (!engine) {
        throw new Error('voice engine missing') as Error;
      }
      const sp: speechRecognizer.StartParams = {
        sessionId: sid,
        audioInfo: { audioType: 'pcm', sampleRate: 16000, soundChannel: 1, sampleBit: 16 }
      };
      engine.startListening(sp);
      return this.makeCapturer();
    }).then((cap: audio.AudioCapturer) => {
      this.voiceCapturer = cap;
      return cap.start();
    }).catch((err: BusinessError) => {
      console.error(`${TAG} voice start failed: ${err.code} ${err.message}`);
      // 201 = permission denied, 4401005/122 = mic not granted
      if (err.code === 201 || err.code === 4401005 || err.code === 122) {
        this.voiceFail('請先打開 hMixed App 授權麥克風');
      } else {
        this.voiceFail('無法啟動語音輸入');
      }
    });
  }

  private makeCapturer(): Promise<audio.AudioCapturer> {
    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
      channels: audio.AudioChannel.CHANNEL_1,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
    };
    const capturerInfo: audio.AudioCapturerInfo = {
      source: audio.SourceType.SOURCE_TYPE_MIC,
      capturerFlags: 0
    };
    const opts: audio.AudioCapturerOptions = {
      streamInfo: streamInfo,
      capturerInfo: capturerInfo
    };
    return audio.createAudioCapturer(opts).then((cap: audio.AudioCapturer) => {
      cap.on('readData', (buff: ArrayBuffer) => {
        this.feedVoice(buff);
      });
      return cap;
    });
  }

  private feedVoice(buff: ArrayBuffer): void {
    const engine = this.voiceEngine;
    if (!engine || !this.voiceOn) {
      return;
    }
    const incoming = new Uint8Array(buff);
    const merged = new Uint8Array(this.voiceBuf.length + incoming.length);
    merged.set(this.voiceBuf, 0);
    merged.set(incoming, this.voiceBuf.length);
    let off: number = 0;
    while (merged.length - off >= 1280) {
      try {
        engine.writeAudio(this.voiceSessionId, merged.subarray(off, off + 1280));
      } catch (e) {
        const be = e as BusinessError;
        console.error(`${TAG} writeAudio: ${be.code}`);
        break;
      }
      off += 1280;
    }
    this.voiceBuf = merged.slice(off);
  }

  private voiceComplete(): void {
    this.stopCapturer();
    const text: string = this.voiceText;
    console.info(`${TAG} voice complete: "${text}"`);
    if (text.length > 0) {
      this.commitText(text);
    }
  }

  private voiceFail(hint: string): void {
    this.stopCapturer();
    try {
      this.voiceEngine?.cancel(this.voiceSessionId);
    } catch (e) {
      // cancel of a not-started session is fine
    }
    this.voiceOn = false;
    this.voiceHint = hint;
    this.notifyUi();
  }

  private stopCapturer(): void {
    const cap = this.voiceCapturer;
    this.voiceCapturer = undefined;
    if (cap) {
      cap.stop().then(() => cap.release()).catch((e: BusinessError) => {
        console.warn(`${TAG} capturer stop: ${e.code}`);
      });
    }
  }

  public setUiListener(listener: UiListener | undefined): void {
    this.uiListener = listener;
    if (listener) {
      listener(this.composition, this.candidates, this.predicting, this.shiftOn, this.rowHeight,
        this.voiceOn, this.voiceHint, this.isCollapsed(), this.physicalKbActive);
    }
  }

  private notifyUi(): void {
    if (this.uiListener) {
      this.uiListener(this.composition, this.candidates, this.predicting, this.shiftOn, this.rowHeight,
        this.voiceOn, this.voiceHint, this.isCollapsed(), this.physicalKbActive);
    }
  }

  private resetComposition(): void {
    this.composition = '';
    this.baseCands = [];
    this.candidates = [];
    this.predicting = false;
    this.shiftOn = false;
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

  /** A letter key was pressed: extend the composition and look up candidates. */
  public onChar(ch: string): void {
    this.predicting = false;
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

  /** Enter: commit what is typed as plain letters. */
  public onEnter(): void {
    if (this.composition.length > 0) {
      this.commitText(this.rawCand().text);
      return;
    }
    this.commitText('\n');
  }

  /**
   * Backspace: shorten the composition while typing; otherwise always delete
   * in the client (and drop any related-word suggestions).
   */
  public onBackspace(): void {
    console.info(`${TAG} onBackspace comp=${this.composition} predicting=${this.predicting} hasClient=${this.inputClient !== undefined}`);
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
    this.commitText(ch);
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
