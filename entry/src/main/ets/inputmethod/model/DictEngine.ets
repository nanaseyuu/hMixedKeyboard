import { util } from '@kit.ArkTS';
import { resourceManager } from '@kit.LocalizationKit';

/**
 * One dictionary candidate.
 *
 * Format per explain.md of github.com/holleeb/Mixed-Chinese-Keyboard-Plus-Dicts:
 * one entry per line:  key \t candidates \n
 * - candidates are runs of `[N]text` where the ASCII digit prefix N is the
 *   CHARACTER LENGTH of the candidate (candidates of length 1 have no prefix);
 * - \u0000 begins the traditional-rare tier, \b begins the simplified tier,
 *   \f begins the simplified-rare tier (order: trad, tradRare, simp, simpRare);
 * - within a tier candidates are already in frequency order - do not re-sort.
 *
 * Dictionary keys are the typed code WITHOUT its first letter: code "aa" is
 * stored as key "a" in file mix_map_bas_a.ms2, single-letter codes are stored
 * under the empty key at the top of the file. The file for a query is picked
 * by the first letter, and by the second letter for the split:
 * _x = 2nd letter a..k (type 2A), _x1 = 2nd letter l..z (type 2B),
 * _0 = keys not starting with a letter (type 3). ext_* files layer on top of
 * bas_* files and must not override them.
 */
export class Cand {
  text: string = '';
  simplified: boolean = false;
  isRaw: boolean = false;
}

export class LookupResult {
  exact: Cand[] = [];
  suggest: Cand[] = [];
}

const DICT_DIR: string = 'dict';

// Unicode boundaries of phrase_N.ms2 related-word groups (first character codepoint).
const PHRASE_BOUNDS: number[] = [21413, 23460, 25238, 26999, 29281, 31757, 33769, 36076, 38287];

const MAX_SUGGEST: number = 16;

export class DictEngine {
  private resourceManager: resourceManager.ResourceManager | undefined;
  private decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
  // key -> raw payload for the letter group currently in use (bas/ext kept apart)
  private basMap: Map<string, string> = new Map();
  private extMap: Map<string, string> = new Map();
  // sorted key lists of the maps above: prefix suggestions binary-search these
  // instead of scanning every key on each keystroke
  private basSorted: string[] = [];
  private extSorted: string[] = [];
  private curGroup: string = '';
  // related-word groups: only the last used group is kept
  private phraseCache: Map<string, string> = new Map();
  private phraseIndex: number = -1;

  public setResourceManager(rm: resourceManager.ResourceManager): void {
    if (this.resourceManager !== rm) {
      this.basMap.clear();
      this.extMap.clear();
      this.curGroup = '';
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
      if (tab < 0) {
        continue;
      }
      // empty keys are valid (single-letter codes): key '' -> payload after tab
      target.set(trimmed.substring(0, tab), trimmed.substring(tab + 1));
    }
  }

  /** Load the bas_/ext_ file pair for the code prefix (first letter + 2A/2B split). */
  private ensureGroup(first: string, second: string): void {
    const isAlpha: boolean = first >= 'a' && first <= 'z';
    const letter: string = isAlpha ? first : '0';
    const use2B: boolean = isAlpha && second >= 'l' && second <= 'z';
    const group: string = `${letter}${use2B ? '1' : ''}`;
    if (group === this.curGroup) {
      return;
    }
    this.curGroup = group;
    this.basMap.clear();
    this.extMap.clear();
    this.parseInto(this.readRawFile(`mix_map_bas_${group}.ms2`), this.basMap);
    this.parseInto(this.readRawFile(`mix_map_ext_${group}.ms2`), this.extMap);
    this.basSorted = this.sortedKeys(this.basMap);
    this.extSorted = this.sortedKeys(this.extMap);
  }

  private sortedKeys(map: Map<string, string>): string[] {
    const keys: string[] = [];
    map.forEach((value: string, k: string) => {
      keys.push(k);
    });
    keys.sort();
    return keys;
  }

  /** Parse one `[N]text`-encoded candidate run within [from, to). */
  private parseSection(payload: string, from: number, to: number, simplified: boolean, out: Cand[]): void {
    let i: number = from;
    while (i < to) {
      const numStart: number = i;
      while (i < to) {
        const code: number = payload.charCodeAt(i);
        if (code >= 48 && code <= 57) {
          i++;
        } else {
          break;
        }
      }
      let len: number = 1;
      if (i > numStart) {
        // digit prefix = character length of the following candidate
        const n: number = parseInt(payload.substring(numStart, i), 10);
        if (i >= to) {
          break; // trailing digits with no text: malformed, drop
        }
        len = Math.min(n, to - i);
      }
      const cand = new Cand();
      cand.text = payload.substring(i, i + len);
      cand.simplified = simplified;
      out.push(cand);
      i += len;
    }
  }

  private parsePayload(payload: string): Cand[] {
    const out: Cand[] = [];
    let nul: number = -1;
    let bs: number = -1;
    let ff: number = -1;
    for (let i = 0; i < payload.length; i++) {
      const code: number = payload.charCodeAt(i);
      if (code === 0 && nul < 0) {
        nul = i;
      } else if (code === 8 && bs < 0) {
        bs = i;
      } else if (code === 12 && ff < 0) {
        ff = i;
      }
    }
    const tradEnd: number = nul >= 0 ? nul : (bs >= 0 ? bs : (ff >= 0 ? ff : payload.length));
    this.parseSection(payload, 0, tradEnd, false, out);
    // rare tiers only count when their markers follow the tier order
    if (nul >= 0) {
      const rareEnd: number = bs > nul ? bs : (ff > nul ? ff : payload.length);
      this.parseSection(payload, nul + 1, rareEnd, false, out);
    }
    if (bs >= 0) {
      const simpEnd: number = ff > bs ? ff : payload.length;
      this.parseSection(payload, bs + 1, simpEnd, true, out);
      if (ff > bs) {
        this.parseSection(payload, ff + 1, payload.length, true, out);
      }
    }
    return out;
  }

  public lookup(query: string): LookupResult {
    const result = new LookupResult();
    if (query.length === 0) {
      return result;
    }
    const first: string = query.charAt(0);
    const second: string = query.length > 1 ? query.charAt(1) : '';
    this.ensureGroup(first, second);
    const isAlpha: boolean = first >= 'a' && first <= 'z';
    // dictionary keys drop the code's first letter; single-letter codes key on ''
    const keys: string[] = [];
    if (isAlpha) {
      keys.push(query.length > 1 ? query.substring(1) : '');
    } else {
      keys.push(query);
      if (query.length > 1) {
        keys.push(query.substring(1));
      }
    }
    for (const key of keys) {
      const base: string | undefined = this.basMap.get(key);
      if (base !== undefined) {
        result.exact.push(...this.parsePayload(base));
      }
      const ext: string | undefined = this.extMap.get(key);
      if (ext !== undefined) {
        result.exact.push(...this.parsePayload(ext));
      }
    }
    if (query.length >= 2) {
      const key: string = isAlpha && query.length > 1 ? query.substring(1) : query;
      this.collectSuggest(this.basMap, this.basSorted, key, result);
      this.collectSuggest(this.extMap, this.extSorted, key, result);
    }
    return result;
  }

  /** First index with keys[index] >= prefix in the sorted list. */
  private lowerBound(keys: string[], prefix: string): number {
    let lo: number = 0;
    let hi: number = keys.length;
    while (lo < hi) {
      const mid: number = (lo + hi) >> 1;
      if (keys[mid] < prefix) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /**
   * Longer keys that start with the query, top 2 candidates each, capped at
   * MAX_SUGGEST. Sorted keys make this a binary search plus a short forward
   * walk — the old map.forEach scanned every key in the group per keystroke.
   */
  private collectSuggest(map: Map<string, string>, keys: string[],
    prefix: string, result: LookupResult): void {
    let budget: number = MAX_SUGGEST - result.suggest.length;
    let i: number = this.lowerBound(keys, prefix);
    while (i < keys.length && budget > 0) {
      const k: string = keys[i];
      if (!k.startsWith(prefix)) {
        break;
      }
      i++;
      if (k.length <= prefix.length) {
        continue; // the exact key itself is already in the exact tier
      }
      const value: string | undefined = map.get(k);
      if (value === undefined) {
        continue;
      }
      const cands: Cand[] = this.parsePayload(value);
      for (let j = 0; j < Math.min(2, cands.length) && budget > 0; j++) {
        result.suggest.push(cands[j]);
        budget--;
      }
    }
  }

  /** Related-word suggestions: phrase candidates are suffixes appended to the word. */
  public predict(word: string): Cand[] {
    if (word.length === 0) {
      return [];
    }
    const cp: number = word.codePointAt(0) ?? 0;
    let idx: number = 0;
    while (idx < PHRASE_BOUNDS.length && cp > PHRASE_BOUNDS[idx]) {
      idx++;
    }
    if (idx !== this.phraseIndex) {
      this.phraseCache.clear();
      this.parseInto(this.readRawFile(`phrase_${idx}.ms2`), this.phraseCache);
      this.phraseIndex = idx;
    }
    const payload: string | undefined = this.phraseCache.get(word);
    if (payload === undefined) {
      return [];
    }
    const suffixes: Cand[] = this.parsePayload(payload);
    const out: Cand[] = [];
    for (const suffix of suffixes) {
      const cand = new Cand();
      cand.text = word + suffix.text;
      cand.simplified = suffix.simplified;
      out.push(cand);
    }
    return out;
  }
}

export const dictEngine: DictEngine = new DictEngine();
