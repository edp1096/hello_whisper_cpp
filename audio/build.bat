@echo off
REM Build miniaudio.dll using gcc (MinGW or TDM-GCC)
REM Requirements:
REM   - miniaudio.h (from https://github.com/mackron/miniaudio)
REM   - stb_vorbis.c (from https://github.com/nothings/stb)
REM Place both files in the same directory as this script

echo Building miniaudio.dll with stb_vorbis support...

gcc -shared -o miniaudio.dll miniaudio_wrapper.c stb_vorbis_impl.c ^
    -O2 ^
    -DMINIAUDIO_IMPLEMENTATION ^
    -DMA_ENABLE_VORBIS ^
    -DMA_NO_JACK ^
    -DMA_NO_RUNTIME_LINKING ^
    -lwinmm -lole32 ^
    -static-libgcc ^
    -Wl,--out-implib,libminiaudio.a

if %errorlevel% equ 0 (
    echo Build successful! miniaudio.dll created.
    echo OGG files will use high-quality stb_vorbis decoder.
) else (
    echo Build failed!
    exit /b 1
)
