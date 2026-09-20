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

## 3. Voice typing via long-press of Space  — pending (feasibility TBD)
Hold the space key to start voice input. Needs investigation whether this SDK
exposes an on-device speech recognizer usable from a third-party IME
(CoreSpeechKit / microphone permission in the IME process). If available,
implement long-press detection on Space + mic capture + recognition.

## 4. Hide soft keyboard when a physical keyboard is connected  — implemented, needs on-device test with a real keyboard
(feasibility TBD) When an external physical keyboard is attached, the soft
keyboard should hide automatically (and return when detached). Implemented:
inputDevice change events + getKeyboardTypeSync classification in
MixedController (ALPHABETIC/DIGITAL keyboards only; panel re-hides on every
system re-show while connected, restores when the last one disconnects).
Deployed on the tablet; still needs a connect/disconnect cycle with a real
Bluetooth/folio keyboard to verify.
