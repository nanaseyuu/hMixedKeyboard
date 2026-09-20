@echo off
setlocal
cd /d "%~dp0"
set "CLI=C:\Program Files\Huawei\CLI"
set "DEVECO_SDK_HOME=%CLI%\sdk"
set "NODE_HOME=%CLI%\tool\node"
set "PATH=%CLI%\tool\node;%CLI%\bin;%PATH%"
call "%CLI%\bin\ohpm.bat" install --all
echo OHPM_RC=%errorlevel%
