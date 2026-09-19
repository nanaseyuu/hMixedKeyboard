@echo off
cd /d C:\Users\tokim\DevEcoStudioProjects\hMixedKeyboard
set DEVECO_SDK_HOME=C:\Program Files\Huawei\DevEco Studio\sdk
set PATH=C:\Program Files\Huawei\DevEco Studio\jbr\bin;%PATH%
"C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js" --mode module -p module=entry@default -p product=default -p buildMode=debug assembleHap --no-daemon
