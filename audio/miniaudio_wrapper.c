// Enable stb_vorbis header for OGG decoding
// Implementation is in separate stb_vorbis_impl.c file
#define STB_VORBIS_HEADER_ONLY
#include "stb_vorbis.c"

// Note: MINIAUDIO_IMPLEMENTATION and MA_ENABLE_VORBIS are defined in the build script via -D flags

#include "miniaudio.h"

// Helper function to get decoder output info
void ma_decoder_get_output_info(ma_decoder* pDecoder, ma_format* pFormat, ma_uint32* pChannels, ma_uint32* pSampleRate) {
    if (pDecoder) {
        if (pFormat) *pFormat = pDecoder->outputFormat;
        if (pChannels) *pChannels = pDecoder->outputChannels;
        if (pSampleRate) *pSampleRate = pDecoder->outputSampleRate;
    }
}

// Get size of ma_decoder structure
size_t ma_decoder_sizeof(void) {
    return sizeof(ma_decoder);
}

// Allocate decoder on heap
ma_decoder* ma_decoder_alloc(void) {
    return (ma_decoder*)malloc(sizeof(ma_decoder));
}

// Free decoder
void ma_decoder_free(ma_decoder* pDecoder) {
    if (pDecoder) {
        free(pDecoder);
    }
}