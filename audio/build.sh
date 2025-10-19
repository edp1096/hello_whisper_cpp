#!/bin/bash
# Build miniaudio shared library with stb_vorbis support
# Requirements:
#   - miniaudio.h (from https://github.com/mackron/miniaudio)
#   - stb_vorbis.c (from https://github.com/nothings/stb)

echo "Building miniaudio shared library with stb_vorbis..."

# Detect OS
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    gcc -shared -o miniaudio.dylib miniaudio_wrapper.c stb_vorbis_impl.c \
        -O2 \
        -DMINIAUDIO_IMPLEMENTATION \
        -DMA_ENABLE_VORBIS \
        -DMA_NO_JACK \
        -DMA_NO_RUNTIME_LINKING \
        -fPIC
    
    if [ $? -eq 0 ]; then
        echo "Build successful! miniaudio.dylib created."
        echo "OGG files will use high-quality stb_vorbis decoder."
    else
        echo "Build failed!"
        exit 1
    fi
else
    # Linux
    gcc -shared -o miniaudio.so miniaudio_wrapper.c stb_vorbis_impl.c \
        -O2 \
        -DMINIAUDIO_IMPLEMENTATION \
        -DMA_ENABLE_VORBIS \
        -DMA_NO_JACK \
        -DMA_NO_RUNTIME_LINKING \
        -fPIC \
        -lpthread -lm -ldl

    if [ $? -eq 0 ]; then
        echo "Build successful! miniaudio.so created."
        echo "OGG files will use high-quality stb_vorbis decoder."
    else
        echo "Build failed!"
        exit 1
    fi
fi
