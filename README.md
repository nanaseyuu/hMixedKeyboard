# hMixedKeyboard

A Cantonese input method for **HarmonyOS NEXT / HarmonyOS 6 and above**, built as a
standalone Input Method Engine (IME) with the
[Mixed Chinese Keyboard (MCK) dictionary](https://github.com/holleeb/Mixed-Chinese-Keyboard-Plus-Dicts).

The keyboard uses the Mixed Chinese Keyboard code scheme (mixed jyutping / pinyin codes,
e.g. `aa` → 晶, `du` → Cantonese phrases), presenting **traditional candidates first**
with simplified variants dimmed alongside, plus a related-word (联想) prediction row.

## Features

- HarmonyOS `InputMethodExtensionAbility` (InputMethod Kit), registered as a system
  input method with a `zh-HK` subtype.
- Mixed Chinese Keyboard **v2.1 (`.ms2`) dictionary engine**: lazy per-initial-letter
  loading, exact match + prefix suggestions, and phrase-dictionary based prediction.
- Multi form-factor: `phone / tablet / 2in1 / tv / car / wearable` device types, with the
  keyboard panel sized in **vp** against the live display metrics (and re-resized on
  display change / rotation).
- Traditional-first candidate ordering with dimmed simplified duplicates.

## Project layout

```
entry/src/main/ets/inputmethod/
  HMixedService.ets        # InputMethodExtensionAbility entry point
  model/MixedController.ets  # panel lifecycle, resize, input event routing
  model/DictEngine.ets       # .ms2 dictionary parser / lookup / prediction
  pages/KeyboardIndex.ets    # ArkUI keyboard panel (candidate bar + QWERTY)
entry/src/main/resources/rawfile/dict/   # MCK dictionary (.ms2, ~37 MB)
```

## Building

1. Open the project in **DevEco Studio 6** (SDK 6.0.2 / API 22 or above).
2. Generate a signing profile: **File → Project Structure → Signing Configs →
   Automatically generate signature** (signing material is not committed to this repo).
3. Build: **Build → Build HAP(s)**, or from a terminal with DevEco's node/jbr on `PATH`:

   ```bat
   build_cli.bat
   ```

## Deploying to a device

```bat
hdc install -r entry\build\default\outputs\default\entry-default-signed.hap

:: enable + switch to hMixedKeyboard
hdc shell ime -e com.greennno.hmixedkeyboard
hdc shell ime -s com.greennno.hmixedkeyboard

:: back to the stock Celia keyboard
hdc shell ime -s com.huawei.hmos.inputmethod
```

Also usable from the tablet: **Settings → System → Language & input → Input methods**.

## Implementation notes

- `Panel.resize()` validates against display size in **vp**, not pixels — passing pixel
  dimensions fails with error `12800008 ("size is invalid")`. The controller divides
  display pixels by `densityPixels` before resizing.
- Call `setUiContent()` **before** the first `resize()`; a failed resize aborts the
  init chain and leaves the panel with a null UIContent.
- The `.ms2` format: `key\tpayload` lines, sections separated by control bytes
  (`\x00`, `\x08`, `\x0c`) for traditional / traditional-rare / simplified tiers; an
  ASCII digit prefix marks ranked multi-character candidates.

## Credits

- Dictionary data: [holleeb/Mixed-Chinese-Keyboard-Plus-Dicts](https://github.com/holleeb/Mixed-Chinese-Keyboard-Plus-Dicts) (Apache-2.0),
  derived from the [Mixed Chinese Keyboard](https://github.com/yanguolvde/MixedChineseKeyboard) project.
- IME architecture referenced from the official OpenHarmony
  `KikaInputMethod` sample (Apache-2.0).

## License

Apache License 2.0 — see [LICENSE](LICENSE).
