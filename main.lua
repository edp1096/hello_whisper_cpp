local ffi = require "ffi"

package.path = package.path .. ";./?.lua"

local audio_conv = require "audio_conv"

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

    int whisper_full_lang_id(struct whisper_context * ctx);
    const char * whisper_lang_str(int id);

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

local function transcribe_and_print(whisper, ctx, audio_data, n_samples, auto_detect, translate, convert_to_cp949)
    local params = whisper.whisper_full_default_params(0)

    if auto_detect then
        params.language = nil
        params.detect_language = false
    else
        params.language = "ko"
        params.detect_language = false
    end

    params.translate = translate
    params.print_progress = false

    local result = whisper.whisper_full(ctx, params, audio_data, n_samples)

    if result == 0 then
        if auto_detect then
            local lang_id = whisper.whisper_full_lang_id(ctx)
            local lang_str = ffi.string(whisper.whisper_lang_str(lang_id))
            print("Detected language: " .. lang_str)
        end

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
local ctx = whisper.whisper_init_from_file("ggml-base-q5_1.bin")
if ctx == nil then
    error("Failed to initialize whisper context")
end

print("\nLoading audio file with miniaudio...")
local audio_file = "sample1.wav"
local audio_data, n_samples = audio_conv.load_audio(audio_file, 16000)

print(string.format("Loaded %d samples at 16000 Hz (%.2f seconds)\n", n_samples, n_samples / 16000))

print("=== Auto-detected Language (Original) ===")
transcribe_and_print(whisper, ctx, audio_data, n_samples, true, false, true)

print("\n=== English Translation ===")
transcribe_and_print(whisper, ctx, audio_data, n_samples, false, true, false)

whisper.whisper_free(ctx)
print("\nDone!")
