package.path = package.path .. ";./?.lua"

local whisper = require("whisper")

local function print_usage()
    print("Usage: luajit cli.lua [options] <audio_file>")
    print("")
    print("Options:")
    print("  -m, --model <path>      Model file path (default: models/ggml-base-q5_1.bin)")
    print("  -l, --language <code>   Language code (default: ko)")
    print("  -a, --auto-detect       Auto-detect language")
    print("  -t, --translate         Translate to English")
    print("  --utf8                  Force UTF-8 output (disable auto-conversion)")
    print("  -h, --help              Show this help message")
    print("")
    print("Examples:")
    print("  luajit cli.lua samples/sample1.wav")
    print("  luajit cli.lua -a -t samples/sample1.wav")
    print("  luajit cli.lua --model models/ggml-large-v3.bin --language en audio.mp3")
end

local function parse_args(args)
    local options = {
        model = "models/ggml-base-q5_1.bin",
        language = "ko",
        auto_detect = false,
        translate = false,
        utf8 = false,
        audio_file = nil
    }

    local i = 1
    while i <= #args do
        local arg = args[i]

        if arg == "-h" or arg == "--help" then
            print_usage()
            os.exit(0)
        elseif arg == "-m" or arg == "--model" then
            i = i + 1
            if i > #args then
                error("Missing value for " .. arg)
            end
            options.model = args[i]
        elseif arg == "-l" or arg == "--language" then
            i = i + 1
            if i > #args then
                error("Missing value for " .. arg)
            end
            options.language = args[i]
        elseif arg == "-a" or arg == "--auto-detect" then
            options.auto_detect = true
        elseif arg == "-t" or arg == "--translate" then
            options.translate = true
        elseif arg == "--utf8" then
            options.utf8 = true
        elseif not arg:match("^%-") then
            if options.audio_file then
                error("Multiple audio files specified")
            end
            options.audio_file = arg
        else
            error("Unknown option: " .. arg)
        end

        i = i + 1
    end

    if not options.audio_file then
        error("No audio file specified")
    end

    return options
end

local function main()
    if #arg == 0 then
        print_usage()
        os.exit(1)
    end

    local ok, options = pcall(parse_args, arg)
    if not ok then
        print("Error: " .. options)
        print("")
        print_usage()
        os.exit(1)
    end

    print("Initializing Whisper model: " .. options.model)
    local whisper_ctx, err = whisper.create_context(options.model)
    if not whisper_ctx then
        print("Error: " .. err)
        os.exit(1)
    end

    print("Processing audio file: " .. options.audio_file)

    local result, err = whisper.transcribe(whisper_ctx, options.audio_file, {
        language = options.language,
        auto_detect = options.auto_detect,
        translate = options.translate
    })

    if not result then
        print("Error: " .. err)
        whisper.free_context(whisper_ctx)
        os.exit(1)
    end

    if result.language then
        print("Detected language: " .. result.language)
    end

    print(string.format("Audio duration: %.2f seconds", result.duration))
    print("")

    if #result.segments == 0 then
        print("No speech detected!")
    else
        for _, segment in ipairs(result.segments) do
            local text = segment.text
            if not options.utf8 then
                text = whisper.utf8_to_console(text)
            end
            print(string.format("[%.2fs -> %.2fs]: %s", segment.start, segment["end"], text))
        end
    end

    whisper.free_context(whisper_ctx)
end

main()
