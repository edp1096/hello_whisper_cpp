local ffi = require("ffi")

ffi.cdef [[
    typedef int32_t ma_result;
    typedef uint8_t ma_uint8;
    typedef uint32_t ma_uint32;
    typedef uint64_t ma_uint64;
    typedef int8_t ma_int8;
    typedef int16_t ma_int16;
    typedef int32_t ma_int32;
    typedef int64_t ma_int64;

    typedef enum {
        ma_format_unknown = 0,
        ma_format_u8      = 1,
        ma_format_s16     = 2,
        ma_format_s24     = 3,
        ma_format_s32     = 4,
        ma_format_f32     = 5,
        ma_format_count
    } ma_format;

    typedef struct ma_decoder ma_decoder;

    typedef struct {
        ma_format  outputFormat;
        ma_uint32  outputChannels;
        ma_uint32  outputSampleRate;
    } ma_decoder_config;

    ma_decoder_config ma_decoder_config_init(ma_format outputFormat, ma_uint32 outputChannels, ma_uint32 outputSampleRate);
    ma_decoder_config ma_decoder_config_init_default(void);

    ma_result ma_decoder_init_file(const char* pFilePath, const ma_decoder_config* pConfig, ma_decoder* pDecoder);
    ma_result ma_decoder_uninit(ma_decoder* pDecoder);
    ma_result ma_decoder_read_pcm_frames(ma_decoder* pDecoder, void* pFramesOut, ma_uint64 frameCount, ma_uint64* pFramesRead);
    ma_result ma_decoder_get_length_in_pcm_frames(ma_decoder* pDecoder, ma_uint64* pLength);

    void ma_decoder_get_output_info(ma_decoder* pDecoder, ma_format* pFormat, ma_uint32* pChannels, ma_uint32* pSampleRate);

    size_t ma_decoder_sizeof(void);
    ma_decoder* ma_decoder_alloc(void);
    void ma_decoder_free(ma_decoder* pDecoder);

    void* malloc(size_t size);
    void free(void* ptr);
]]

local MA_SUCCESS = 0

local ma = ffi.load("vendor/miniaudio/miniaudio.dll")

local audio_conv = {}

function audio_conv.load_audio(filepath, target_sample_rate)
    target_sample_rate = target_sample_rate or 16000

    local decoder = ma.ma_decoder_alloc()
    if decoder == nil then
        error("Failed to allocate decoder memory")
    end

    local result = ma.ma_decoder_init_file(filepath, nil, decoder)

    if result ~= MA_SUCCESS then
        ma.ma_decoder_free(decoder)
        error("Failed to load audio file: " .. filepath .. " (error code: " .. tonumber(result) .. ")")
    end

    local format = ffi.new("ma_format[1]")
    local channels = ffi.new("ma_uint32[1]")
    local sample_rate = ffi.new("ma_uint32[1]")
    ma.ma_decoder_get_output_info(decoder, format, channels, sample_rate)

    local actual_rate = tonumber(sample_rate[0])
    local actual_channels = tonumber(channels[0])
    local actual_format = tonumber(format[0])

    local length_ptr = ffi.new("ma_uint64[1]")
    result = ma.ma_decoder_get_length_in_pcm_frames(decoder, length_ptr)

    local total_frames
    if result == MA_SUCCESS then
        total_frames = tonumber(length_ptr[0])
    else
        total_frames = actual_rate * 60
    end

    local buffer_size = total_frames * actual_channels
    local frames_read_ptr = ffi.new("ma_uint64[1]")

    local raw_buffer
    if actual_format == 2 then     -- ma_format_s16
        raw_buffer = ffi.new("int16_t[?]", buffer_size)
    elseif actual_format == 5 then -- ma_format_f32
        raw_buffer = ffi.new("float[?]", buffer_size)
    else
        ma.ma_decoder_uninit(decoder)
        ma.ma_decoder_free(decoder)
        error("Unsupported format: " .. actual_format)
    end

    result = ma.ma_decoder_read_pcm_frames(decoder, raw_buffer, total_frames, frames_read_ptr)

    local actual_frames = tonumber(frames_read_ptr[0])

    ma.ma_decoder_uninit(decoder)
    ma.ma_decoder_free(decoder)

    if result ~= MA_SUCCESS and actual_frames == 0 then
        error("Failed to read audio data from: " .. filepath)
    end

    local float_samples = ffi.new("float[?]", buffer_size)
    if actual_format == 2 then -- s16 to float
        for i = 0, buffer_size - 1 do
            float_samples[i] = tonumber(raw_buffer[i]) / 32768.0
        end
    else -- already float
        for i = 0, buffer_size - 1 do
            float_samples[i] = raw_buffer[i]
        end
    end

    local mono_samples = ffi.new("float[?]", actual_frames)

    if actual_channels == 2 then
        for i = 0, actual_frames - 1 do
            mono_samples[i] = (float_samples[i * 2] + float_samples[i * 2 + 1]) / 2.0
        end
    elseif actual_channels == 1 then
        for i = 0, actual_frames - 1 do
            mono_samples[i] = float_samples[i]
        end
    else
        for i = 0, actual_frames - 1 do
            mono_samples[i] = float_samples[i * actual_channels]
        end
    end

    local final_samples, final_frames
    if actual_rate ~= target_sample_rate then
        local ratio = actual_rate / target_sample_rate
        final_frames = math.floor(actual_frames / ratio)
        final_samples = ffi.new("float[?]", final_frames)

        for i = 0, final_frames - 1 do
            local src_pos = i * ratio
            local src_idx = math.floor(src_pos)
            local frac = src_pos - src_idx

            if src_idx >= actual_frames then
                final_samples[i] = mono_samples[actual_frames - 1]
            elseif src_idx < actual_frames - 1 then
                final_samples[i] = mono_samples[src_idx] * (1 - frac) + mono_samples[src_idx + 1] * frac
            else
                final_samples[i] = mono_samples[src_idx]
            end
        end
    else
        final_samples = mono_samples
        final_frames = actual_frames
    end

    return final_samples, final_frames
end

function audio_conv.get_file_info(filepath)
    local decoder = ma.ma_decoder_alloc()
    if decoder == nil then
        return nil, "Failed to allocate decoder memory"
    end

    local result = ma.ma_decoder_init_file(filepath, nil, decoder)

    if result ~= MA_SUCCESS then
        ma.ma_decoder_free(decoder)
        return nil, "Failed to open file"
    end

    local format = ffi.new("ma_format[1]")
    local channels = ffi.new("ma_uint32[1]")
    local sample_rate = ffi.new("ma_uint32[1]")

    ma.ma_decoder_get_output_info(decoder, format, channels, sample_rate)

    local length_ptr = ffi.new("ma_uint64[1]")
    ma.ma_decoder_get_length_in_pcm_frames(decoder, length_ptr)

    local info = {
        format = tonumber(format[0]),
        channels = tonumber(channels[0]),
        sample_rate = tonumber(sample_rate[0]),
        length_frames = tonumber(length_ptr[0])
    }

    ma.ma_decoder_uninit(decoder)
    ma.ma_decoder_free(decoder)

    return info
end

return audio_conv
