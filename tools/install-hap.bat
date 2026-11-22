@echo off
chcp 65001 >nul
setlocal

rem 默认用 DevEco 自带的 hdc；如果 PATH 里有 hdc 就用 PATH 的
set "HDC=C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
if not exist "%HDC%" set "HDC=hdc"

set "HAP=%~1"
if "%HAP%"=="" set "HAP=entry\build\default\outputs\default\entry-default-signed.hap"

echo ============================
echo  已连接设备
echo ============================
"%HDC%" list targets

echo.
echo ============================
echo  各设备 UDID（要发给开发者加白名单）
echo ============================
"%HDC%" shell bm get --udid

echo.
set /p GO=确认安装 %HAP% 吗？(y/N)
if /i not "%GO%"=="y" goto :eof

echo.
echo 正在安装...
"%HDC%" install "%HAP%"

echo.
echo 如果报 9568322 / signature verification failed，
echo 说明这台机器的 UDID 还没加进调试 Profile，需要重新申请签名后再装。
pause
