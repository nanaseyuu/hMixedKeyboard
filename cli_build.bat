@echo off
setlocal
cd /d "%~dp0"
set "CLI=C:\Program Files\Huawei\CLI"
set "DEVECO_SDK_HOME=%CLI%\sdk"
set "NODE_HOME=%CLI%\tool\node"
set "JAVA_HOME=C:\Program Files\Huawei\DevEco Studio\jbr"
set "PATH=%CLI%\tool\node;%CLI%\bin;%JAVA_HOME%\bin;%PATH%"
call "%CLI%\bin\hvigorw.bat" --sync -p product=default --no-daemon
echo SYNC_RC=%errorlevel%
call "%CLI%\bin\hvigorw.bat" assembleHap --mode module -p module=entry@default -p product=default -p buildMode=debug --no-daemon
echo BUILD_RC=%errorlevel%
