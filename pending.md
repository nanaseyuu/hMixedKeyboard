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
net if the bar ever gets hidden while an editor is still attached.
Physical-key typing is captured via `KeyboardDelegate.on('keyEvent')`:
letters build pinyin with candidates in the bar; digits 1-9/0 pick numbered
candidates; any other symbol sends the raw English plus that symbol; Space
sends raw English; arrow keys navigate a highlight (incl. the un-numbered
raw chip, auto-scrolled into view) that Space/Enter commits. 漢/EN button in
the collapsed bar hands the keys back to the app for plain English typing.
Verified on MatePad Edge and Mate XTS.

## 5. Candidate selection via a separate toolbar window instead of the IME panel  — pending
Background: the IME soft-keyboard panel window is heavily restricted by the
system — `moveWindowTo` is silently ignored, `startMoving` hides the panel,
`FLG_FIXED` windows are clamped to full screen width. The current candidate
strip therefore lives inside a full-width transparent band pinned to the
bottom edge, and can only slide horizontally.
Idea: stop insisting on the keyboard panel for candidate selection. Create a
SEPARATE window (e.g. `window.createWindow` with a freeform/float type from
the IME extension context) whose only job is showing candidates + selection.
A plain floating window is not bound by soft-keyboard panel rules, so it
could be freely draggable in 2D and positioned anywhere. The IME panel would
then only render the full keyboard (or nothing, when a physical keyboard is
attached). Open questions: can an IME extension create and show arbitrary
windows (permission/system restrictions), z-order vs. the app in focus, and
touch routing when it overlaps app content.
Feasibility note: estimated ~30% — floating windows above other apps'
content normally require the system-grade `SYSTEM_FLOAT_WINDOW` permission
that third-party apps don't get. Worth a one-hour spike: attempt one
`createWindow` (float type) from the extension context and read the
permission error. If denied, the current in-band strip stands.

## 6. Container apps (EasyAbroad / droitong): input bridging via an APK helper  — pending
Problem: Android-compat containers (EasyAbroad, droitong) double-deliver
physical keystrokes — the keys reach our IME (composition builds, candidates
show) but the container ALSO injects the raw English into the focused editor,
so Chinese cannot be typed with the physical keyboard inside those apps.
Idea A: ship a small companion APK that runs INSIDE the container as an
Android accessibility service (or local input method). It would capture
keystrokes/targeted edit fields in container apps, forward them to the
HarmonyOS side (localhost socket / intent bridge), receive back the committed
Chinese text, and write it into the field — effectively an input bridge that
suppresses the container's own raw-key path.
Idea B (fallback if A is infeasible): a native Android keyboard app running
inside the container only, sharing the same dictionary/engine (the MCK
dictionary format is pure data, so the parsing logic could be ported or the
HarmonyOS side could serve lookups over the local bridge).
Open questions: can a container-side service suppress the container's key
delivery; is cross-environment networking (HarmonyOS host ↔ Android
container) allowed on localhost; does EasyAbroad permit installing helper
APKs with accessibility privileges.
Feasibility note: ~50% and a real project (a full Android app). The
double-delivery we observed suggests the container bypasses Android's input
framework — which is also what would defeat the helper's key filtering.
Try item 7 (delete-back fix) and item 5's spike before committing to this.
Documented workaround for now: tap `^` on the candidate bar to expand the
full on-screen keyboard and tap-type Chinese — that path works in container
apps (verified on Mate XTS).

## 7. Container fix, cheap attempt: delete-back-then-commit  — pending
Keys DO reach our IME inside container apps (composition builds; commits
work). The only defect is the container ALSO typing the raw letters into the
editor. So: let them land. While composing with a physical keyboard in a
container app, count the raw characters the editor received; when a candidate
is committed, delete that many characters back (the selectByRange+CUT /
deleteBackward strategies already work — see the backspace fix) and only then
insert the Chinese text. ~20 lines in the existing app instead of an APK
project. Might fail if the container ignores our deletes the way it ignores
key consumption — an afternoon to find out. Try this BEFORE item 6.

## 8. Candidate bar as a real floating panel  — mostly done, manual test pending
The transparent full-width band approach (v1 of the fix) was REVERTED: an
IME system window is full-width regardless of ArkUI transparency, and
HitTestMode games cannot pass touches to the app behind it. Final
architecture (commit pending manual finger test):

- Expanded (no physical keyboard, or `^` tapped): `FLG_FIXED` panel,
  full width, bottom-pinned. Measured on MatePad Edge:
  `softKeyboard2 [0, 1457, 3120, 623]`.
- Physical keyboard attached: `FLG_FLOATING` panel, resized to 40% width
  x COLLAPSED_VP. Measured: `softKeyboard1 [0, 0, 1248, 114]` — genuinely
  narrow, so nothing outside that rect is blocked by construction.
- Mode switches destroy + recreate the panel through a serialized
  transition coordinator (generation tokens, stale-panel destroy,
  coalescing, reconcile-after-complete). Verified round trip
  collapsed -> expanded -> collapsed via `^` / chevron.
- A recreated panel sometimes never receives vsync and renders nothing;
  fixed with a generation-guarded hide/show nudge 700ms after each
  transition.
- Docking verified on MatePad Edge: Panel.moveTo(0, 1841) lands the
  collapsed panel exactly between the app area and the taskbar
  (`softKeyboard [0, 1841, 1248, 114]`, taskbar `[0, 1955, 3120, 125]`,
  no overlap; strip content pixel-verified non-black). Caveat found:
  moveTo on a VISIBLE panel blanks the surface, so the dock move is
  performed before show(), with guarded same-coordinate retries after
  show, after the vsync nudge, and whenever the reported inset changes.
- Placement finalised: the docked panel is horizontally CENTRED
  (`[936, 1841, 1248, 114]` on Edge), verified through an expand/collapse
  round trip.
- Bottom-inset fix: the expanded keyboard's dock spacer is now applied
  only when the avoid-area query MEASURES a real dock (>= 50vp). The old
  unconditional 40vp fallback added a phantom ~115px blank band on the
  Mate XTs (gap below keys: ours 264px vs Jyutping 202px vs Celia 120px);
  the XTs window now matches Jyutping (`[0, 1309, 1008, 794]`, gap ~142px)
  while the Edge keeps its measured taskbar inset (expanded
  `[0, 1407, 3120, 673]`).
- Known limitation: injected (automation) touches do not reach buttons on
  floating IME panels, so strip button interactivity at the docked
  position still needs a real-finger confirmation.
- Focus changes no longer recreate a matching panel (an earlier draft
  rebuilt the panel on every `inputStart`, flashing the bar; fixed).

Verified by automation on device: narrow/expanded rectangles, round trip,
physical-key injection reaching the IME (`physKey code=2017 pinyin=true`),
candidate chips rendering in the strip (pixel check), dock/app touches
landing behind the strip (a dock tap opened the assistant; page clicks
reached the browser behind). STILL REQUIRES the human finger test: outside-
strip clicks, folio typing + chip tap commits Chinese, `^`/chevron round
trip. Known limitation: the system pins the floating panel top-left and
ignores all move requests; vertical placement is not possible.

Deploy lessons (keep): always show `hdc file send` output — silent transfer
failures made `bm install` deploy a stale hap (verify the
`onCreate enter — build <stamp>` line). The hilog buffer churns in ~10s:
stream `hilog` to a file instead of snapshotting. Heavy install churn can
flip the IME to BASIC_MODE (recover: switch to Celia, force-stop ours,
`ime -e` ours, `ime -s` ours). Panel windows are named `softKeyboard<N>`
(N increments per re-creation; FLOATING ones are findable via
`window.findWindow`, FIXED ones are not).
