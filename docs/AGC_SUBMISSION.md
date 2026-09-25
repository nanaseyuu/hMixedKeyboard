# AppGallery submission checklist (Mixed KB)

Target: Huawei AppGallery, HarmonyOS NEXT (API 22). Package: `.app`
(release-signed bundle of HAPs). Bundle: `com.greennno.hmixedkeyboard`.

## 1. Prerequisites (account, one-time)

- [ ] Huawei developer account at developer.huawei.com (individual is fine
      for free apps), identity/bank real-name verification completed.
- [ ] AppGallery Connect (AGC) -> My apps -> New app:
      - Package name: `com.greennno.hmixedkeyboard` (must match app.json5)
      - Category: Apps -> Utilities (input method)
      - Default language: en (add zh after)
- [ ] **Release signing material** (AGC -> Certificate/App ID/Profile):
      - Release certificate (.cer). One release cert per account.
      - Release provisioning profile (.p7b) for bundle
        `com.greennno.hmixedkeyboard`. Release profiles are NOT limited to
        device UDIDs (that is a debug-profile thing).
      - Download both; keep the release keystore (.p12 + .csr) from DevEco
        (Build > Project Structure > Signing Configs, release tab).

## 2. Build the upload package

- [ ] Point `build-profile.json5` signingConfigs at the RELEASE
      certificate + profile (never commit this file).
- [ ] DevEco: Build > Build App(s)/Hap(s) > **Build App(s)** ->
      `entry/build/default/outputs/**/*.app`.
- Debug-signed HAPs are rejected by AGC: the current local
  `entry-default-signed.hap` is debug-signed and is NOT uploadable.

## 3. App assets AGC will demand

- [ ] App icon 655x655 PNG, no rounded corners (already have a layered
      icon; export a flat 655 from it).
- [ ] 3-5 screenshots per distributed form factor (phone, tablet, 2in1):
      show the QWERTY view with Cantonese candidates, the symbol pages,
      the collapsed candidate bar with the physical keyboard.
- [ ] Privacy policy URL (publicly reachable - GitHub Pages works, see
      docs/PRIVACY_POLICY.md draft) and user agreement URL.
- [ ] App introduction (<= 450 chars) - short draft: "Cantonese
      pinyin/jyutping-style input method for HarmonyOS: offline dictionary
      candidate engine, physical-keyboard candidate strip, voice input."
- [ ] Version info: versionName 1.0.0, versionCode 1000000 (must grow with
      every submission).

## 4. Review-sensitive points for an IME

- [ ] Data safety form: voice typing uses ONLINE speech recognition
      (zh-CN) - declare audio data collection/transient processing, or
      turn voice typing off for v1 and ship it in v1.1 with the form done.
- [ ] Permission justifications: microphone (voice typing), vibrate (key
      press feedback). No location/contacts/anything else is used.
- [ ] Input-method apps get extra manual review: expect a reviewer
      testing candidate output in their own notes app. No account/login
      is required, so no tester credentials are needed.
- [ ] The dictionary (MCK Plus, Apache-2.0) is bundled - attribution in
      the app description ("dictionary data: holleeb/Mixed-Chinese-
      Keyboard-Plus-Dicts, Apache-2.0") avoids licence complaints.

## 5. Known non-blockers / hygiene

- vendor field was "example" -> fixed to "greennno".
- deviceTypes trimmed to phone/tablet/2in1 (car/wearable/tv made no
  sense for an IME and would extend compatibility review).
- Debug vs release: `cli_build.bat` builds debug; use the release flow
  above for anything uploaded.
