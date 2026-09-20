@echo off
rem Template of the local sign+install script. Copy to cli_sign_install.bat and
rem fill in KEYSTORE_PWD before use. Never commit the real cli_sign_install.bat.
setlocal
cd /d "%~dp0"
set "CLI=C:\Program Files\Huawei\CLI"
set "JAVA=C:\Program Files\Huawei\DevEco Studio\jbr\bin\java.exe"
set "HDC=%CLI%\sdk\default\openharmony\toolchains\hdc.exe"
set "SIGNTOOL=%CLI%\sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar"
set "OUT=entry\build\default\outputs\default"
set "DEV_ADDR=192.168.101.174:39717"

if not exist "signing\hmixed.cer" exit /b 1
if not exist "signing\hmixed.p7b" exit /b 1
if not exist "%OUT%\entry-default-unsigned.hap" exit /b 1

echo === signing ===
"%JAVA%" -jar "%SIGNTOOL%" sign-app -keyAlias "hmixed_key" -signAlg "SHA256withECDSA" -mode "localSign" -appCertFile "signing\hmixed.cer" -profileFile "signing\hmixed.p7b" -inFile "%OUT%\entry-default-unsigned.hap" -keystoreFile "signing\hmixed.p12" -outFile "%OUT%\entry-default-signed.hap" -keyPwd "%KEYSTORE_PWD%" -keystorePwd "%KEYSTORE_PWD%" || exit /b 1

echo === ensuring device connection ===
"%HDC%" list targets | findstr /i "192.168" >nul 2>&1
if errorlevel 1 (
  "%HDC%" kill >nul 2>&1
  ping -n 3 127.0.0.1 >nul
  "%HDC%" start >nul 2>&1
  ping -n 2 127.0.0.1 >nul
  "%HDC%" tconn %DEV_ADDR%
)
"%HDC%" list targets

echo === installing ===
"%HDC%" file send "%OUT%\entry-default-signed.hap" "data/local/tmp/entry-default-signed.hap" || exit /b 1
"%HDC%" shell bm install -p "data/local/tmp/entry-default-signed.hap" || exit /b 1
"%HDC%" shell rm -rf "data/local/tmp/entry-default-signed.hap"

echo === enabling hMixedKeyboard ===
"%HDC%" shell ime -e com.greennno.hmixedkeyboard || exit /b 1
"%HDC%" shell ime -s com.greennno.hmixedkeyboard || exit /b 1
echo === DONE ===
