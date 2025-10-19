local ffi = require("ffi")
local audio_conv = require("audio_conv")

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

local whisper_module = {}

function whisper_module.utf8_to_acp(utf8_str)
    if not utf8_str or utf8_str == "" then
        return ""
    end

    local wide_len = ffi.C.MultiByteToWideChar(CP_UTF8, 0, utf8_str, -1, nil, 0)
    if wide_len <= 0 then
        return utf8_str
    end

    local wide_str = ffi.new("wchar_t[?]", wide_len)
    ffi.C.MultiByteToWideChar(CP_UTF8, 0, utf8_str, -1, wide_str, wide_len)

    local acp_len = ffi.C.WideCharToMultiByte(CP_ACP, 0, wide_str, -1, nil, 0, nil, nil)
    if acp_len <= 0 then
        return utf8_str
    end

    local acp_str = ffi.new("char[?]", acp_len)
    ffi.C.WideCharToMultiByte(CP_ACP, 0, wide_str, -1, acp_str, acp_len, nil, nil)

    return ffi.string(acp_str)
end

whisper_module.utf8_to_cp949 = whisper_module.utf8_to_acp

function whisper_module.get_console_codepage()
    local is_windows = package.config:sub(1, 1) == '\\'
    if not is_windows then
        return nil
    end

    local handle = io.popen("chcp 2>nul")
    if not handle then
        return 949
    end

    local output = handle:read("*a")
    handle:close()

    local codepage = output:match("(%d+)")
    return tonumber(codepage) or 949
end

function whisper_module.utf8_to_console(utf8_str)
    local codepage = whisper_module.get_console_codepage()

    if not codepage or codepage == 65001 then
        return utf8_str
    end

    return whisper_module.utf8_to_acp(utf8_str)
end

function whisper_module.create_context(model_path)
    local whisper_lib = ffi.load("whisper.dll")
    local ctx = whisper_lib.whisper_init_from_file(model_path)
    if ctx == nil then
        return nil, "Failed to initialize whisper context"
    end
    return {
        ctx = ctx,
        lib = whisper_lib
    }
end

function whisper_module.free_context(whisper_ctx)
    if whisper_ctx and whisper_ctx.ctx then
        whisper_ctx.lib.whisper_free(whisper_ctx.ctx)
        whisper_ctx.ctx = nil
    end
end

function whisper_module.transcribe(whisper_ctx, audio_file, options)
    options = options or {}
    local language = options.language or "ko"
    local auto_detect = options.auto_detect or false
    local translate = options.translate or false
    local sample_rate = options.sample_rate or 16000

    local audio_data, n_samples = audio_conv.load_audio(audio_file, sample_rate)

    local params = whisper_ctx.lib.whisper_full_default_params(0)

    if auto_detect then
        params.language = nil
        params.detect_language = false
    else
        params.language = language
        params.detect_language = false
    end

    params.translate = translate
    params.print_progress = false

    local result = whisper_ctx.lib.whisper_full(whisper_ctx.ctx, params, audio_data, n_samples)

    if result ~= 0 then
        return nil, "Transcription failed with code: " .. result
    end

    local detected_language = nil
    if auto_detect then
        local lang_id = whisper_ctx.lib.whisper_full_lang_id(whisper_ctx.ctx)
        detected_language = ffi.string(whisper_ctx.lib.whisper_lang_str(lang_id))
    end

    local segments = {}
    local n_segments = whisper_ctx.lib.whisper_full_n_segments(whisper_ctx.ctx)

    for i = 0, n_segments - 1 do
        local text = ffi.string(whisper_ctx.lib.whisper_full_get_segment_text(whisper_ctx.ctx, i))
        local t0 = tonumber(whisper_ctx.lib.whisper_full_get_segment_t0(whisper_ctx.ctx, i)) / 100.0
        local t1 = tonumber(whisper_ctx.lib.whisper_full_get_segment_t1(whisper_ctx.ctx, i)) / 100.0

        table.insert(segments, {
            text = text,
            start = t0,
            ["end"] = t1
        })
    end

    return {
        segments = segments,
        language = detected_language,
        duration = n_samples / sample_rate
    }
end

return whisper_module
