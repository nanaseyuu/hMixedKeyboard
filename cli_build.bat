@echo off
setlocal
cd /d "%~dp0"
set "CLI=C:\Program Files\Huawei\CLI"
set "DEVECO_SDK_HOME=%CLI%\sdk"
set "NODE_HOME=%CLI%\tool\node"
set "JAVA_HOME=C:\Program Files\Huawei\DevEco Studio\jbr"
set "PATH=%CLI%\tool\node;%CLI%\bin;%JAVA_HOME%\bin;%PATH%"
rem DevEco-written signingConfigs are encrypted per-machine and break hvigor's
rem SignHap elsewhere (00303107). The CLI pipeline signs separately via
rem cli_sign_install.bat, so build against an empty-config copy and restore.
copy /y build-profile.json5 build-profile.local.json5 >nul
powershell -NoProfile -Command "$c=[IO.File]::ReadAllText('build-profile.local.json5'); $c=[regex]::Replace($c,'\"signingConfigs\":\s*\[[\s\S]*?\]','\"signingConfigs\": []'); [IO.File]::WriteAllText('build-profile.json5',$c)"
call "%CLI%\bin\hvigorw.bat" --sync -p product=default --no-daemon
echo SYNC_RC=%errorlevel%
call "%CLI%\bin\hvigorw.bat" assembleHap --mode module -p module=entry@default -p product=default -p buildMode=debug --no-daemon
set "BUILD_RC=%errorlevel%"
copy /y build-profile.local.json5 build-profile.json5 >nul
del build-profile.local.json5 >nul 2>&1
echo BUILD_RC=%BUILD_RC%
