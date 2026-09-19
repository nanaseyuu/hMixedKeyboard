import { inputMethodEngine, InputMethodExtensionContext } from '@kit.IMEKit';
import { display } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { Cand, dictEngine, LookupResult } from './DictEngine';

export type UiListener = (composition: string, candidates: Cand[], predicting: boolean) => void;

const TAG: string = 'MixedController';
const KEYBOARD_HEIGHT_RATE_PORTRAIT: number = 0.42;
const KEYBOARD_HEIGHT_RATE_LANDSCAPE: number = 0.5;

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

  private composition: string = '';
  private candidates: Cand[] = [];
  private predicting: boolean = false;

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

  private initWindow(): void {
    if (!this.context) {
      console.error(`${TAG} initWindow: no context`);
      return;
    }
    const dis = display.getDefaultDisplaySync();
    const isLandscape = dis.width > dis.height;
    // the panel resize API validates sizes against the display in vp units
    const density = dis.densityPixels > 0 ? dis.densityPixels : 1;
    const widthVp = Math.floor(dis.width / density);
    const keyHeightVp = Math.floor((isLandscape ? dis.width : dis.height) *
      (isLandscape ? KEYBOARD_HEIGHT_RATE_LANDSCAPE : KEYBOARD_HEIGHT_RATE_PORTRAIT) / density);
    this.panelWidth = widthVp;
    this.panelHeight = keyHeightVp;
    console.info(`${TAG} initWindow: display ${dis.width}x${dis.height}, density ${density}, panel ${widthVp}x${keyHeightVp}vp`);
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
          // the panel window only becomes resizable once it exists; the system
          // may also consider a freshly created panel "already shown", so hide
          // it first, size it, and let the system show it on demand
          this.panel.on('show', () => {
            console.info(`${TAG} panel show event`);
            this.resizeWithRetry(this.panelWidth, this.panelHeight, 1);
          });
          console.info(`${TAG} panel initial hide`);
          return this.panel.hide().then(() => {
            console.info(`${TAG} panel hidden, resizing`);
            return this.resizeWithRetry(this.panelWidth, this.panelHeight, 1);
          }).catch((err: BusinessError) => {
            console.error(`${TAG} panel hide failed: code ${err.code}`);
            return this.resizeWithRetry(this.panelWidth, this.panelHeight, 1);
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
      this.kbController = kbController;
      this.inputClient = inputClient;
      this.resetComposition();
    });
    ability.on('inputStop', () => {
      this.resetComposition();
    });
    display.on('change', () => {
      this.resizePanel();
    });
  }

  private resizePanel(): void {
    const dis = display.getDefaultDisplaySync();
    const isLandscape = dis.width > dis.height;
    const keyHeight = Math.floor((isLandscape ? dis.width : dis.height) *
      (isLandscape ? KEYBOARD_HEIGHT_RATE_LANDSCAPE : KEYBOARD_HEIGHT_RATE_PORTRAIT));
    if (this.panel) {
      this.panel.resize(dis.width, keyHeight).catch((err: BusinessError) => {
        console.error(`${TAG} resizePanel: ${err.code} ${err.message}`);
      });
    }
  }

  public setUiListener(listener: UiListener | undefined): void {
    this.uiListener = listener;
    if (listener) {
      listener(this.composition, this.candidates, this.predicting);
    }
  }

  private notifyUi(): void {
    if (this.uiListener) {
      this.uiListener(this.composition, this.candidates, this.predicting);
    }
  }

  private resetComposition(): void {
    this.composition = '';
    this.candidates = [];
    this.predicting = false;
    this.notifyUi();
  }

  /** A letter key was pressed: extend the composition and look up candidates. */
  public onChar(ch: string): void {
    this.predicting = false;
    this.composition += ch;
    const result: LookupResult = dictEngine.lookup(this.composition);
    this.candidates = result.exact.concat(result.suggest);
    this.notifyUi();
  }

  public onNumeric(ch: string): void {
    this.commitText(ch);
  }

  /** Space: commit the first candidate, else commit the raw code, else type a space. */
  public onSpace(): void {
    if (this.candidates.length > 0) {
      this.commitCandidate(this.candidates[0]);
      return;
    }
    if (this.composition.length > 0) {
      this.commitText(this.composition);
      return;
    }
    this.commitText(' ');
  }

  /** Enter: commit what is typed as plain letters. */
  public onEnter(): void {
    if (this.composition.length > 0) {
      this.commitText(this.composition);
      return;
    }
    this.commitText('\n');
  }

  /** Backspace: shorten the composition, else delete in the client. */
  public onBackspace(): void {
    if (this.composition.length > 0) {
      this.composition = this.composition.substring(0, this.composition.length - 1);
      if (this.composition.length === 0) {
        this.resetComposition();
        return;
      }
      const result: LookupResult = dictEngine.lookup(this.composition);
      this.candidates = result.exact.concat(result.suggest);
      this.notifyUi();
      return;
    }
    if (this.inputClient) {
      this.inputClient.deleteBackward(1).catch((err: BusinessError) => {
        console.error(`${TAG} deleteBackward: ${err.code} ${err.message}`);
      });
    }
  }

  public chooseCandidate(index: number): void {
    if (index >= 0 && index < this.candidates.length) {
      this.commitCandidate(this.candidates[index]);
    }
  }

  /** Punctuation: flush the pending composition first, then type the symbol. */
  public onPunctuation(ch: string): void {
    if (this.composition.length > 0) {
      this.commitText(this.composition);
    }
    this.commitText(ch);
  }

  private commitCandidate(cand: Cand): void {
    this.commitText(cand.text);
  }

  private commitText(text: string): void {
    if (this.inputClient) {
      this.inputClient.insertText(text).catch((err: BusinessError) => {
        console.error(`${TAG} insertText: ${err.code} ${err.message}`);
      });
    }
    const committed = text;
    this.composition = '';
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
