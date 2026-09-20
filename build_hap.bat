@echo off
rem CLI build for hMixedKeyboard debug HAP. Run AFTER DevEco Studio 6.0.2 (API 22)
rem is installed AND signing config has been generated (File > Project Structure >
rem Signing Configs > Automatically generate signature).
setlocal
cd /d "%~dp0"

set "DEVECO=C:\Program Files\Huawei\DevEco Studio"
set "DEVECO_SDK_HOME=%DEVECO%\sdk"
set "PATH=%DEVECO%\tools\node;%DEVECO%\jbr\bin;%PATH%"
set "NODE_HOME=%DEVECO%\tools\node"

echo === ohpm install ===
call "%DEVECO%\tools\ohpm\bin\ohpm.bat" install --all || exit /b 1

echo === hvigor assembleHap (debug) ===
call "%DEVECO%\tools\node\node.exe" "%DEVECO%\tools\hvigor\bin\hvigorw.js" --sync -p product=default --no-daemon || exit /b 1
call "%DEVECO%\tools\node\node.exe" "%DEVECO%\tools\hvigor\bin\hvigorw.js" assembleHap --mode module -p module=entry@default -p product=default -p buildMode=debug --no-daemon || exit /b 1

set "HAP=entry\build\default\outputs\default\entry-default-signed.hap"
if not exist "%HAP%" (
  echo ERROR: "%HAP%" not found. Signing config is probably missing. 1>&2
  echo If an unsigned HAP exists, check File ^> Project Structure ^> Signing Configs. 1>&2
  dir /b "entry\build\default\outputs\default" 2>nul
  exit /b 1
)
echo === Built OK: %HAP% ===
