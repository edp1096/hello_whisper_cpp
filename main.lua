local ffi = require("ffi")

ffi.cdef [[
    typedef struct whisper_context whisper_context;
    typedef int32_t whisper_token;

    struct whisper_context * whisper_init_from_file(const char * path_model);
    void whisper_free(struct whisper_context * ctx);

    typedef enum {
        WHISPER_SAMPLING_GREEDY = 0,
        WHISPER_SAMPLING_BEAM_SEARCH = 1,
    } whisper_sampling_strategy;

    typedef struct whisper_vad_params {
        float threshold;
        int   min_speech_duration_ms;
        int   min_silence_duration_ms;
        float max_speech_duration_s;
        int   speech_pad_ms;
        float samples_overlap;
    } whisper_vad_params;

    struct whisper_full_params {
        int strategy;
        int n_threads;
        int n_max_text_ctx;
        int offset_ms;
        int duration_ms;
        bool translate;
        bool no_context;
        bool no_timestamps;
        bool single_segment;
        bool print_special;
        bool print_progress;
        bool print_realtime;
        bool print_timestamps;
        bool token_timestamps;
        float thold_pt;
        float thold_ptsum;
        int max_len;
        bool split_on_word;
        int max_tokens;
        bool debug_mode;
        int audio_ctx;
        bool tdrz_enable;
        const char * suppress_regex;
        const char * initial_prompt;
        bool carry_initial_prompt;
        const whisper_token * prompt_tokens;
        int prompt_n_tokens;
        const char * language;
        bool detect_language;
        bool suppress_blank;
        bool suppress_nst;
        float temperature;
        float max_initial_ts;
        float length_penalty;
        float temperature_inc;
        float entropy_thold;
        float logprob_thold;
        float no_speech_thold;
        struct {
            int best_of;
        } greedy;
        struct {
            int beam_size;
            float patience;
        } beam_search;
        void * new_segment_callback;
        void * new_segment_callback_user_data;
        void * progress_callback;
        void * progress_callback_user_data;
        void * encoder_begin_callback;
        void * encoder_begin_callback_user_data;
        void * abort_callback;
        void * abort_callback_user_data;
        void * logits_filter_callback;
        void * logits_filter_callback_user_data;
        const void ** grammar_rules;
        size_t n_grammar_rules;
        size_t i_start_rule;
        float grammar_penalty;
        bool vad;
        const char * vad_model_path;
        whisper_vad_params vad_params;
    };

    struct whisper_full_params whisper_full_default_params(int strategy);

    int whisper_full(
        struct whisper_context * ctx,
        struct whisper_full_params params,
        const float * samples,
        int n_samples);

    int whisper_full_n_segments(struct whisper_context * ctx);

    const char * whisper_full_get_segment_text(
        struct whisper_context * ctx,
        int i_segment);

    int64_t whisper_full_get_segment_t0(
        struct whisper_context * ctx,
        int i_segment);

    int64_t whisper_full_get_segment_t1(
        struct whisper_context * ctx,
        int i_segment);

    typedef struct FILE FILE;
    FILE *fopen(const char *filename, const char *mode);
    int fclose(FILE *stream);
    size_t fread(void *ptr, size_t size, size_t nmemb, FILE *stream);
    void *malloc(size_t size);
    void free(void *ptr);

    typedef unsigned short wchar_t;
    int MultiByteToWideChar(unsigned int CodePage, unsigned long dwFlags, const char* lpMultiByteStr, int cbMultiByte, wchar_t* lpWideCharStr, int cchWideChar);
    int WideCharToMultiByte(unsigned int CodePage, unsigned long dwFlags, const wchar_t* lpWideCharStr, int cchWideChar, char* lpMultiByteStr, int cbMultiByte, const char* lpDefaultChar, int* lpUsedDefaultChar);
]]

local CP_UTF8 = 65001
local CP_ACP = 0

local function utf8_to_cp949(utf8_str)
    if not utf8_str or utf8_str == "" then
        return ""
    end

    local wide_len = ffi.C.MultiByteToWideChar(CP_UTF8, 0, utf8_str, -1, nil, 0)
    if wide_len <= 0 then
        return utf8_str
    end

    local wide_str = ffi.new("wchar_t[?]", wide_len)
    ffi.C.MultiByteToWideChar(CP_UTF8, 0, utf8_str, -1, wide_str, wide_len)

    local cp949_len = ffi.C.WideCharToMultiByte(CP_ACP, 0, wide_str, -1, nil, 0, nil, nil)
    if cp949_len <= 0 then
        return utf8_str
    end

    local cp949_str = ffi.new("char[?]", cp949_len)
    ffi.C.WideCharToMultiByte(CP_ACP, 0, wide_str, -1, cp949_str, cp949_len, nil, nil)

    return ffi.string(cp949_str)
end

-- Resample basic - Nearest neighbor
local function resample_audio_basic(samples, n_samples, src_rate, dst_rate)
    local ratio = src_rate / dst_rate
    local new_n_samples = math.floor(n_samples / ratio)
    local resampled = ffi.new("float[?]", new_n_samples)

    for i = 0, new_n_samples - 1 do
        local src_idx = math.floor(i * ratio)
        if src_idx < n_samples then
            resampled[i] = samples[src_idx]
        end
    end

    return resampled, new_n_samples
end

-- Resample Linear
local function resample_audio_linear(samples, n_samples, src_rate, dst_rate)
    local ratio = src_rate / dst_rate
    local new_n_samples = math.floor(n_samples / ratio)
    local resampled = ffi.new("float[?]", new_n_samples)

    for i = 0, new_n_samples - 1 do
        local src_pos = i * ratio
        local src_idx = math.floor(src_pos)
        local frac = src_pos - src_idx

        if src_idx < n_samples - 1 then
            resampled[i] = samples[src_idx] * (1 - frac) + samples[src_idx + 1] * frac
        elseif src_idx < n_samples then
            resampled[i] = samples[src_idx]
        end
    end

    return resampled, new_n_samples
end

local function read_wav_file(filename)
    local file = ffi.C.fopen(filename, "rb")
    if file == nil then
        error("Failed to open file: " .. filename)
    end

    local header = ffi.new("uint8_t[44]")
    ffi.C.fread(header, 1, 44, file)

    local channels = header[22] + header[23] * 256
    local sample_rate = header[24] + header[25] * 256 + header[26] * 65536 + header[27] * 16777216
    local bits_per_sample = header[34] + header[35] * 256
    local data_size = header[40] + header[41] * 256 + header[42] * 65536 + header[43] * 16777216

    print(string.format("WAV Info - Channels: %d, Sample Rate: %d Hz, Bits: %d", channels, sample_rate, bits_per_sample))

    local num_samples = data_size / (bits_per_sample / 8) / channels
    local raw_data = ffi.C.malloc(data_size)
    ffi.C.fread(raw_data, 1, data_size, file)
    ffi.C.fclose(file)

    local samples = ffi.new("float[?]", num_samples)

    if bits_per_sample == 16 then
        local int16_data = ffi.cast("int16_t*", raw_data)
        for i = 0, num_samples - 1 do
            local sample_val = 0
            if channels == 1 then
                sample_val = int16_data[i]
            else
                sample_val = int16_data[i * channels]
            end
            samples[i] = sample_val / 32768.0
        end
    elseif bits_per_sample == 32 then
        local float_data = ffi.cast("float*", raw_data)
        for i = 0, num_samples - 1 do
            if channels == 1 then
                samples[i] = float_data[i]
            else
                samples[i] = float_data[i * channels]
            end
        end
    end

    ffi.C.free(raw_data)

    return samples, num_samples, sample_rate
end

local function transcribe_and_print(whisper, ctx, audio_data, n_samples, language, translate, convert_to_cp949)
    local params = whisper.whisper_full_default_params(0)
    params.language = language
    params.translate = translate
    params.print_progress = false

    local result = whisper.whisper_full(ctx, params, audio_data, n_samples)

    if result == 0 then
        local n_segments = whisper.whisper_full_n_segments(ctx)
        if n_segments == 0 then
            print("No speech detected!")
        else
            for i = 0, n_segments - 1 do
                local text = ffi.string(whisper.whisper_full_get_segment_text(ctx, i))
                if convert_to_cp949 then
                    text = utf8_to_cp949(text)
                end
                local t0 = tonumber(whisper.whisper_full_get_segment_t0(ctx, i)) / 100.0
                local t1 = tonumber(whisper.whisper_full_get_segment_t1(ctx, i)) / 100.0
                print(string.format("[%.2fs -> %.2fs]: %s", t0, t1, text))
            end
        end
    else
        print("Failed with code: " .. result)
    end
end

local whisper = ffi.load("whisper.dll")

print("Initializing Whisper model...")
local ctx = whisper.whisper_init_from_file("ggml-base.bin")
if ctx == nil then
    error("Failed to initialize whisper context")
end

print("\nReading audio file...")
local audio_data, n_samples, sample_rate = read_wav_file("sample1.wav")

local target_rate = 16000
if sample_rate ~= target_rate then
    print(string.format("Resampling from %d Hz to %d Hz...", sample_rate, target_rate))
    -- audio_data, n_samples = resample_audio_basic(audio_data, n_samples, sample_rate, target_rate)
    audio_data, n_samples = resample_audio_linear(audio_data, n_samples, sample_rate, target_rate)
    sample_rate = target_rate
end

print(string.format("Processing %d samples at %d Hz (%.2f seconds)\n", n_samples, sample_rate, n_samples / sample_rate))

print("=== Korean Original ===")
transcribe_and_print(whisper, ctx, audio_data, n_samples, "ko", false, true)

print("\n=== English Translation ===")
transcribe_and_print(whisper, ctx, audio_data, n_samples, "ko", true, false)

whisper.whisper_free(ctx)
print("\nDone!")
