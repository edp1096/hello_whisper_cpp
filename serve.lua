local LUASOCKET_DIR = "vendor/socket"

package.path = package.path .. ";./?.lua;" .. LUASOCKET_DIR .. "/?.lua"
package.cpath = package.cpath .. ";./?.dll;" .. LUASOCKET_DIR .. "/?/core.dll"

local whisper = require("whisper")
local socket = require("socket")

local function json_encode(obj)
    local function escape(s)
        return s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
    end

    if type(obj) == "table" then
        if #obj > 0 then
            local parts = {}
            for i, v in ipairs(obj) do
                parts[i] = json_encode(v)
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            for k, v in pairs(obj) do
                table.insert(parts, '"' .. escape(tostring(k)) .. '":' .. json_encode(v))
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    elseif type(obj) == "string" then
        return '"' .. escape(obj) .. '"'
    elseif type(obj) == "number" or type(obj) == "boolean" then
        return tostring(obj)
    else
        return "null"
    end
end

local function parse_multipart(body, boundary)
    local fields = {}
    local delimiter = "--" .. boundary
    local parts = {}
    local start = 1

    while true do
        local dstart, dend = body:find(delimiter, start, true)
        if not dstart then break end

        if start ~= 1 then
            local part = body:sub(start, dstart - 1)
            if #part > 0 then
                table.insert(parts, part)
            end
        end

        start = dend + 1
        if body:sub(start, start + 1) == "--" then
            break
        end
        if body:sub(start, start + 1) == "\r\n" then
            start = start + 2
        elseif body:sub(start, start) == "\n" then
            start = start + 1
        end
    end

    for _, part in ipairs(parts) do
        local header_end = part:find("\r\n\r\n") or part:find("\n\n")
        if header_end then
            local headers = part:sub(1, header_end - 1)
            local content_start = header_end + (part:sub(header_end, header_end + 3) == "\r\n\r\n" and 4 or 2)
            local content = part:sub(content_start)

            if content:sub(-2) == "\r\n" then
                content = content:sub(1, -3)
            elseif content:sub(-1) == "\n" then
                content = content:sub(1, -2)
            end

            local name = headers:match('name="([^"]+)"')
            local filename = headers:match('filename="([^"]+)"')

            if name then
                fields[name] = { content = content, filename = filename }
            end
        end
    end

    return fields
end

local function handle_client(client, whisper_ctx)
    client:settimeout(10)

    local request_line = client:receive()
    if not request_line then return end

    local method, path = request_line:match("^(%S+)%s+(%S+)")

    local headers = {}
    while true do
        local line = client:receive()
        if not line or line == "" then break end
        local k, v = line:match("^([^:]+):%s*(.+)$")
        if k then headers[k:lower()] = v end
    end

    local function send_json(code, data)
        local body = json_encode(data)
        client:send("HTTP/1.1 " .. code .. "\r\n")
        client:send("Content-Type: application/json\r\n")
        client:send("Content-Length: " .. #body .. "\r\n")
        client:send("Connection: close\r\n\r\n")
        client:send(body)
    end

    if path == "/health" and method == "GET" then
        send_json("200 OK", { status = "ok" })
        return
    end

    if path == "/transcribe" and method == "POST" then
        local content_length = tonumber(headers["content-length"]) or 0
        if content_length == 0 then
            send_json("400 Bad Request", { error = "No content" })
            return
        end

        local body = client:receive(content_length)
        if not body then
            send_json("400 Bad Request", { error = "Failed to read body" })
            return
        end

        local content_type = headers["content-type"] or ""
        local boundary = content_type:match("boundary=([^;%s]+)")
        if not boundary then
            send_json("400 Bad Request", { error = "Missing boundary" })
            return
        end

        local fields = parse_multipart(body, boundary)
        if not fields.file then
            send_json("400 Bad Request", { error = "No file" })
            return
        end

        local filename = fields.file.filename or "audio.wav"
        local ext = filename:match("%.([^%.]+)$") or "wav"
        local temp_dir = os.getenv("TEMP") or os.getenv("TMP") or "."
        local temp_file = temp_dir .. "\\whisper_" .. os.time() .. "_" .. math.random(10000, 99999) .. "." .. ext

        local f = io.open(temp_file, "wb")
        if not f then
            send_json("500 Internal Server Error", { error = "Failed to create temp file" })
            return
        end
        f:write(fields.file.content)
        f:close()

        local result, err = whisper.transcribe(whisper_ctx, temp_file, {
            language = fields.language and fields.language.content or "ko",
            auto_detect = fields.auto_detect and fields.auto_detect.content == "true",
            translate = fields.translate and fields.translate.content == "true"
        })

        os.remove(temp_file)

        if not result then
            send_json("500 Internal Server Error", { error = err })
        else
            send_json("200 OK", result)
        end
        return
    end

    send_json("404 Not Found", { error = "Not found" })
end

local port = tonumber(arg[1]) or 8080
local model = arg[2] or "models/ggml-base-q5_1.bin"

print("Initializing model:", model)
local whisper_ctx = whisper.create_context(model)
if not whisper_ctx then
    print("Failed to load model")
    os.exit(1)
end

local server = socket.tcp()
server:bind("*", port)
server:listen(5)
server:settimeout(0.1)

print("Server running on port", port)
print("Endpoints:")
print("  GET  /health")
print("  POST /transcribe")

while true do
    local client = server:accept()
    if client then
        local ok, err = pcall(handle_client, client, whisper_ctx)
        if not ok then
            print("Error:", err)
        end
        client:close()
    end
end
