// Standalone check of the DictEngine parsing algorithm against the real files.
const fs = require('fs');
const base = 'C:/Users/OseasyVM/DevEcoProjects/hMixedKeyboard/entry/src/main/resources/rawfile/dict/';

function parse(payload) {
  const out = [];
  let nul = -1, bs = -1, ff = -1;
  for (let i = 0; i < payload.length; i++) {
    const c = payload.charCodeAt(i);
    if (c === 0 && nul < 0) nul = i;
    else if (c === 8 && bs < 0) bs = i;
    else if (c === 12 && ff < 0) ff = i;
  }
  const sec = (from, to, s) => {
    let i = from;
    while (i < to) {
      const ns = i;
      while (i < to && payload.charCodeAt(i) >= 48 && payload.charCodeAt(i) <= 57) i++;
      let len = 1;
      if (i > ns) {
        const n = parseInt(payload.substring(ns, i), 10);
        if (i >= to) break;
        len = Math.min(n, to - i);
      }
      out.push({ t: payload.substring(i, i + len), s });
      i += len;
    }
  };
  const te = nul >= 0 ? nul : (bs >= 0 ? bs : (ff >= 0 ? ff : payload.length));
  sec(0, te, false);
  if (nul >= 0) {
    const re = bs > nul ? bs : (ff > nul ? ff : payload.length);
    sec(nul + 1, re, false);
  }
  if (bs >= 0) {
    const se = ff > bs ? ff : payload.length;
    sec(bs + 1, se, true);
    if (ff > bs) sec(ff + 1, payload.length, true);
  }
  return out;
}

function load(name) {
  const m = new Map();
  for (const ln of fs.readFileSync(base + name, 'utf8').split('\n')) {
    const t = ln.indexOf('\t');
    if (t < 0) continue;
    m.set(ln.substring(0, t), ln.substring(t + 1));
  }
  return m;
}

const basA = load('mix_map_bas_a.ms2');
console.log('code aa (key a):', JSON.stringify(parse(basA.get('a')).slice(0, 10)));
console.log('code a  (key ""):', JSON.stringify(parse(basA.get('')).slice(0, 10)));
console.log('code aaa(key aa):', JSON.stringify(parse(basA.get('aa')).slice(0, 10)));

// phrase test: find 抗病 anywhere
for (let i = 0; i < 10; i++) {
  const m = load('phrase_' + i + '.ms2');
  const hit = [...m.keys()].find(k => k.includes('抗病'));
  if (hit !== undefined) {
    console.log('phrase hit', hit, JSON.stringify(parse(m.get(hit)).slice(0, 8)));
    break;
  }
}
// a common prediction sample
for (let i = 0; i < 10; i++) {
  const m = load('phrase_' + i + '.ms2');
  for (const k of m.keys()) {
    if (k === '背景' || k === '朋友' || k === '今天') {
      console.log('phrase', k, '->', JSON.stringify((k + '|') + parse(m.get(k)).slice(0, 6).map(c => k + c.t).join(',')));
    }
  }
}
