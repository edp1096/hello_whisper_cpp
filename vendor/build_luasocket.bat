@echo off
REM Require to download and compile https://github.com/lunarmodules/luasocket
REM Build LuaSocket for Windows using MinGW (gcc)
REM Run this in the luasocket/src directory

echo Building LuaSocket with MinGW...

set LUAJIT_DIR=D:\dev\my-lua-set\luajit
set LUAINC=%LUAJIT_DIR%\include
set LUALIB=%LUAJIT_DIR%\bin\lua51.dll

if not exist socket mkdir socket
if not exist mime mkdir mime

gcc -shared -o socket/core.dll ^
    auxiliar.c buffer.c except.c inet.c io.c ^
    luasocket.c options.c select.c tcp.c timeout.c ^
    udp.c wsocket.c compat.c ^
    -I%LUAINC% ^
    -DLUASOCKET_NODEBUG ^
    -DWINVER=0x0501 ^
    -Wall -O2 -fno-common ^
    %LUALIB% -lws2_32 ^
    -Wl,-s

if %errorlevel% neq 0 (
    echo Failed to build socket core
    exit /b 1
)

gcc -shared -o mime/core.dll ^
    mime.c compat.c ^
    -I%LUAINC% ^
    -DLUASOCKET_NODEBUG ^
    -Wall -O2 -fno-common ^
    %LUALIB% ^
    -Wl,-s

if %errorlevel% neq 0 (
    echo Failed to build mime core
    exit /b 1
)

echo.
echo Build successful!
echo socket/core.dll and mime/core.dll created