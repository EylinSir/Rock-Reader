@echo off
REM RockReader 本机构建入口（装机测试范畴，findings 备忘）
REM 为什么需要它：Git Bash 的 PATH 是 POSIX 视图（冒号分隔），export 后原生进程
REM （node spawn java）的 PATH 查找全废（CreateProcess 要分号格式）——实测
REM bash 里 java -version 都 command not found。cmd 的 set 写的是原生格式，一劳永逸。
REM 用法：cmd //c scripts/build.cmd assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
setlocal
set "PATH=E:\Program Files\Huawei\DevEco Studio\jbr\bin;E:\Program Files\Huawei\DevEco Studio\tools\node;%PATH%"
set "DEVECO_SDK_HOME=E:\Program Files\Huawei\DevEco Studio\sdk"
set "JAVA_HOME=E:\Program Files\Huawei\DevEco Studio\jbr"
node "E:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js" %*
exit /b %ERRORLEVEL%
