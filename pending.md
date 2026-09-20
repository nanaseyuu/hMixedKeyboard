# Pending features

Status legend: pending → in progress → done

## 1. Expand symbols page, add 1/2 paging  — done
The symbols (numeric) page has only ~18 symbols. Missing keys include
`/ \ < > ^ % | [ ] { } ~ ` =`. Add them by introducing a second symbol page;
in numeric mode the Shift key becomes a page switch labeled `1/2` / `2/2`.
Page 2 now carries `[ ] { } < > / \ | ~ ^ ` = _` and common typographic keys.
Verified on device.

## 2. Key press feedback  — done
Keys should show pressed feedback: background turns grey while a key is held
(TouchType.Down), restored on Up/Cancel. Verified on device.

## 3. Voice typing via long-press of Space  — done
Implemented: holding Space ~0.45s starts on-device dictation (CoreSpeechKit
zh-CN, online=1) fed by a 16 kHz mono AudioCapturer; releasing Space finishes
and inserts the recognized text. MICROPHONE is granted via the hMixed entry
app (requestPermissionsFromUser; IME extensions cannot prompt). Caveat: the
recognizer language is Mandarin zh-CN. Verified on device.

## 4. Physical keyboard behaviour — COLLAPSE mode  — done
v1 auto-hid the soft panel when a physical keyboard connected; that made the
keyboard unrecoverable while driving the tablet through the MatePad Edge
keyboard/mouse share (pointer off-screen = no way back). v2 PIN mode kept the
full panel pinned. Current policy (collapse): while a physical keyboard is
attached the panel shrinks to a slim candidate bar (COLLAPSED_VP=60) with a ^
restore arrow on the right — tap ^ for the full keys, ⌄ (shown in the bar when
expanded) to collapse again. Auto re-show after ~600ms is kept as a safety
net if the bar ever gets hidden while an editor is still attached. SDK
caveat: third-party IMEs receive no physical keystrokes at this API level, so
the bar shows candidates only for text typed through the soft panel; physical
typing is handled directly by the system. Verified on device.
