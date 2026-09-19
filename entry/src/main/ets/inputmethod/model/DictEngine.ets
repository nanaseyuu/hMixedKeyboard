import { util } from '@kit.ArkTS';
import { resourceManager } from '@kit.LocalizationKit';

/**
 * One candidate word parsed from a dictionary entry.
 * Dictionaries come from github.com/holleeb/Mixed-Chinese-Keyboard-Plus-Dicts (v2.1, .ms2 plain-text maps).
 */
export class Cand {
  text: string = '';
  rank: number = 0;
  simplified: boolean = false;
}

export class LookupResult {
  exact: Cand[] = [];
  suggest: Cand[] = [];
}

const DICT_DIR: string = 'dict';
const SECTION_TRAD: number = 0;
const SECTION_TRAD_RARE: number = 1;
const SECTION_SIMP: number = 2;
const SECTION_SIMP_RARE: number = 3;

// Unicode boundaries of phrase_N.ms2 related-word groups (first character codepoint).
const PHRASE_BOUNDS: number[] = [21413, 23460, 25238, 26999, 29281, 31757, 33769, 36076, 38287];

const MAX_SUGGEST: number = 16;

/**
 * Loads and queries the Mixed Chinese Keyboard dictionaries.
 *
 * v2.1 .ms2 format, one entry per line:  key \t payload
 * payload is a mix of candidate sections separated by control chars:
 *   traditional \u0000 traditionalRare \u0008 simplified \u000c simplifiedRare
 * Inside a section an ASCII digit starts a new ranked candidate; chars without
 * a digit prefix are single-character candidates in frequency order.
 */
export class DictEngine {
  private resourceManager: resourceManager.ResourceManager | undefined;
  private decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
  // key -> raw payload, only for the letter group currently in use
  private groupCache: Map<string, string> = new Map();
  private groupLetter: string = '';
  // related-word groups: codepoint index -> key -> payload (only the last used group is kept)
  private phraseCache: Map<string, string> = new Map();
  private phraseIndex: number = -1;

  public setResourceManager(rm: resourceManager.ResourceManager): void {
    if (this.resourceManager !== rm) {
      this.groupCache.clear();
      this.groupLetter = '';
      this.phraseCache.clear();
      this.phraseIndex = -1;
    }
    this.resourceManager = rm;
  }

  private readRawFile(name: string): string {
    if (!this.resourceManager) {
      return '';
    }
    try {
      const bytes = this.resourceManager.getRawFileContentSync(`${DICT_DIR}/${name}`);
      return this.decoder.decodeToString(bytes);
    } catch (err) {
      console.error(`hMixedKeyboard dict: cannot read ${name}: ${JSON.stringify(err)}`);
      return '';
    }
  }

  /**
   * Dictionary files are split by the first letter of the key:
   * mix_map_bas_X / mix_map_bas_X1 (base) and mix_map_ext_X / mix_map_ext_X1 (extended).
   */
  private ensureLetterGroup(letter: string): void {
    if (letter === this.groupLetter) {
      return;
    }
    this.groupCache.clear();
    const names: string[] = [];
    if (letter >= 'a' && letter <= 'z') {
      names.push(`mix_map_bas_${letter}.ms2`, `mix_map_bas_${letter}1.ms2`,
        `mix_map_ext_${letter}.ms2`, `mix_map_ext_${letter}1.ms2`);
    } else {
      // numbers and symbols live in the un-suffixed files
      names.push('mix_map_bas.ms2', 'mix_map_ext.ms2');
    }
    for (const name of names) {
      const content = this.readRawFile(name);
      this.parseInto(content, this.groupCache);
    }
    this.groupLetter = letter;
  }

  private parseInto(content: string, target: Map<string, string>): void {
    if (content.length === 0) {
      return;
    }
    const lines = content.split('\n');
    for (const line of lines) {
      const trimmed = line.replace(/\r$/, '');
      if (trimmed.length === 0) {
        continue;
      }
      const tab = trimmed.indexOf('\t');
      if (tab <= 0) {
        continue;
      }
      target.set(trimmed.substring(0, tab), trimmed.substring(tab + 1));
    }
  }

  private parsePayload(payload: string): Cand[] {
    const sections: Cand[][] = [[], [], [], []];
    let section = SECTION_TRAD;
    let cur = '';
    let rank = -1;
    let index = 0;
    const flush = () => {
      if (cur.length > 0) {
        const c = new Cand();
        c.text = cur;
        c.rank = rank < 0 ? 0 : rank;
        c.simplified = section >= SECTION_SIMP;
        c.rank += section * 10; // keep sections apart: trad < tradRare < simp < simpRare
        sections[section].push(c);
        cur = '';
        rank = -1;
      }
      index++;
    };
    for (let i = 0; i < payload.length; i++) {
      const code = payload.charCodeAt(i);
      if (code === 0) {
        flush();
        section = SECTION_TRAD_RARE;
      } else if (code === 8) {
        flush();
        section = SECTION_SIMP;
      } else if (code === 12) {
        flush();
        section = SECTION_SIMP_RARE;
      } else if (code >= 48 && code <= 57) {
        flush();
        rank = code - 48;
      } else {
        cur += payload.charAt(i);
      }
    }
    flush();
    const out: Cand[] = [];
    for (const s of sections) {
      s.sort((a, b) => a.rank - b.rank); // stable, keeps frequency order inside a rank
      out.push(...s);
    }
    return out;
  }

  public lookup(query: string): LookupResult {
    const result = new LookupResult();
    if (query.length === 0) {
      return result;
    }
    const first = query.charAt(0);
    this.ensureLetterGroup(first);
    const payload = this.groupCache.get(query);
    if (payload !== undefined) {
      result.exact = this.parsePayload(payload);
    }
    if (query.length >= 2) {
      // prefix suggestions are only useful once the code is long enough
      let budget = MAX_SUGGEST;
      this.groupCache.forEach((value: string, key: string) => {
        if (budget <= 0) {
          return;
        }
        if (key.length > query.length && key.startsWith(query)) {
          const cands = this.parsePayload(value);
          for (let i = 0; i < Math.min(2, cands.length) && budget > 0; i++) {
            result.suggest.push(cands[i]);
            budget--;
          }
        }
      });
    }
    return result;
  }

  /** Related-word suggestions (phrase_N.ms2) for a committed Chinese word. */
  public predict(word: string): Cand[] {
    if (word.length === 0) {
      return [];
    }
    const cp = word.codePointAt(0) ?? 0;
    let idx = 0;
    while (idx < PHRASE_BOUNDS.length && cp > PHRASE_BOUNDS[idx]) {
      idx++;
    }
    if (idx !== this.phraseIndex) {
      this.phraseCache.clear();
      const content = this.readRawFile(`phrase_${idx}.ms2`);
      this.parseInto(content, this.phraseCache);
      this.phraseIndex = idx;
    }
    const payload = this.phraseCache.get(word);
    if (payload === undefined) {
      return [];
    }
    return this.parsePayload(payload);
  }
}

export const dictEngine: DictEngine = new DictEngine();
