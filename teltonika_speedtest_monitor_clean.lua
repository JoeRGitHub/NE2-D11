-- Teltonika Network Speed Monitor
-- Camera Resolution Recommender

local LOG_FILE = "/tmp/speedtest_monitor.log"
local ELK_LOG_FILE = "/tmp/speedtest_elk_send.log"
local MAX_LOG_SIZE = 200000
local MAX_ELK_LOG_RECORDS = 50
local INTERVAL = 1800
local DEVICE_NAME = "B080"

local function log_message(message)
    local lf = io.open(LOG_FILE, "a")
    if lf then
        lf:write(os.date("%Y-%m-%d %H:%M:%S") .. " : " .. message .. "\n")
        lf:close()
    end
    print(message)
end

local function rotate_log()
    local lf = io.open(LOG_FILE, "r")
    if lf then
        lf:seek("end")
        local size = lf:seek()
        lf:close()
        
        if size and size > MAX_LOG_SIZE then
            os.execute("tail -c 100000 " .. LOG_FILE .. " > " .. LOG_FILE .. ".tmp && mv " .. LOG_FILE .. ".tmp " .. LOG_FILE)
        end
    end
end

local function log_elk_send(status, message, elk_url)
    local timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
    local log_entry = string.format("%s | %s | %s | %s\n", 
                                    timestamp, 
                                    status, 
                                    message or "", 
                                    elk_url or "N/A")
    
    local existing_lines = {}
    local lf = io.open(ELK_LOG_FILE, "r")
    if lf then
        for line in lf:lines() do
            table.insert(existing_lines, line)
        end
        lf:close()
    end
    
    table.insert(existing_lines, log_entry:sub(1, -2))
    
    local start_index = math.max(1, #existing_lines - MAX_ELK_LOG_RECORDS + 1)
    local records_to_keep = {}
    for i = start_index, #existing_lines do
        table.insert(records_to_keep, existing_lines[i])
    end
    
    lf = io.open(ELK_LOG_FILE, "w")
    if lf then
        for _, line in ipairs(records_to_keep) do
            lf:write(line .. "\n")
        end
        lf:close()
    end
end

local function command_exists(cmd)
    local result = os.execute("command -v " .. cmd .. " >/dev/null 2>&1")
    return result == 0 or result == true
end

local function check_install_speedtest()
    log_message("Checking for speedtest...")
    
    if command_exists("speedtest-cli") then
        log_message("speedtest-cli is already installed")
        return true
    end
    
    if command_exists("speedtest") then
        log_message("speedtest is already installed")
        return true
    end
    
    log_message("speedtest not found. Installing...")
    os.execute("opkg update")
    
    local result = os.execute("opkg install speedtest-cli 2>&1 | tee -a " .. LOG_FILE)
    if result == 0 or result == true then
        log_message("speedtest-cli installed successfully")
        return true
    end
    
    result = os.execute("opkg install python3-speedtest-cli 2>&1 | tee -a " .. LOG_FILE)
    if result == 0 or result == true then
        log_message("python3-speedtest-cli installed successfully")
        return true
    end
    
    log_message("ERROR: Failed to install speedtest-cli")
    return false
end

local function recommend_resolution(upload_speed)
    print("")
    print("================================================")
    print("CAMERA RESOLUTION RECOMMENDATION")
    print("================================================")
    print(string.format("Upload Speed: %.2f Mbps", upload_speed))
    print("")
    
    local recommendation
    
    if upload_speed >= 10 then
        print("EXCELLENT: 1080p @ High Bitrate (4-6 Mbps)")
        print("  You can also use 1440p or 4K if camera supports it")
        recommendation = "1080p_high"
    elseif upload_speed >= 5 then
        print("GOOD: 1080p @ Medium Bitrate (3-4 Mbps)")
        print("  Stable full HD streaming")
        recommendation = "1080p_medium"
    elseif upload_speed >= 3 then
        print("FAIR: 720p @ High Bitrate (2-3 Mbps)")
        print("  OR 1080p @ Low Bitrate")
        recommendation = "720p_high"
    elseif upload_speed >= 1.5 then
        print("LIMITED: 720p @ Medium Bitrate (1.5-2 Mbps)")
        print("  Acceptable quality for most purposes")
        recommendation = "720p_medium"
    elseif upload_speed >= 0.8 then
        print("POOR: 480p @ Medium Bitrate (0.8-1.5 Mbps)")
        print("  OR 720p @ Very Low Bitrate")
        recommendation = "480p"
    else
        print("VERY POOR: 360p or Lower (< 0.8 Mbps)")
        print("  Consider upgrading network connection")
        recommendation = "360p"
    end
    
    print("================================================")
    print("")
    
    log_message(string.format("RECOMMENDATION: %s for %.2f Mbps upload", recommendation, upload_speed))
    
    return recommendation
end

local function get_resolution_recommendation(upload_speed)
    if upload_speed >= 10 then
        return "1080p_high"
    elseif upload_speed >= 5 then
        return "1080p_medium"
    elseif upload_speed >= 3 then
        return "720p_high"
    elseif upload_speed >= 1.5 then
        return "720p_medium"
    elseif upload_speed >= 0.8 then
        return "480p"
    else
        return "360p"
    end
end

local function run_speedtest()
    log_message("Running speedtest...")
    print("This may take 30-60 seconds, please wait...")
    
    local cmd
    local use_simple = false
    
    if command_exists("speedtest-cli") then
        cmd = "timeout 90 speedtest-cli --simple 2>&1"
        use_simple = true
    elseif command_exists("speedtest") then
        cmd = "echo y | timeout 90 speedtest 2>&1"
        use_simple = false
    else
        log_message("ERROR: No speedtest command available")
        return false
    end
    
    print("Testing server connection...")
    local handle = io.popen(cmd)
    if not handle then
        log_message("ERROR: Failed to start speedtest")
        return false
    end
    
    local result = handle:read("*a")
    local success = handle:close()
    
    if not result or result == "" then
        log_message("ERROR: Speedtest returned no output (timeout or network issue)")
        return false
    end
    
    if result:match("timed out") or result:match("[Ee]rror") then
        log_message("ERROR: Speedtest failed or timed out")
        log_message(result)
        return false
    end
    
    print(result)
    
    local upload, download, ping
    
    if use_simple then
        upload = result:match("[Uu]pload:%s*([%d%.]+)")
        download = result:match("[Dd]ownload:%s*([%d%.]+)")
        ping = result:match("[Pp]ing:%s*([%d%.]+)")
    else
        local upload_str, upload_unit = result:match(".*Average upload speed is ([%d%.]+)([kmKM]bps)")
        local download_str, download_unit = result:match(".*Average download speed is ([%d%.]+)([kmKM]bps)")
        
        if upload_str then
            upload = tonumber(upload_str)
            if upload_unit:lower():match("^k") then
                upload = upload / 1000
            end
        end
        
        if download_str then
            download = tonumber(download_str)
            if download_unit:lower():match("^k") then
                download = download / 1000
            end
        end
        
        ping = result:match("[Ll]atency:%s*([%d%.]+)") or result:match("[Pp]ing:%s*([%d%.]+)")
    end
    
    if not upload then
        log_message("ERROR: Could not parse upload speed")
        log_message("Raw output: " .. result)
        return false
    end
    
    upload = tonumber(upload) or upload
    download = tonumber(download) or download or 0
    ping = tonumber(ping) or 0
    
    log_message(string.format("Results: Download=%.2fMbps, Upload=%.2fMbps, Ping=%.2fms", 
                              download, upload, ping))
    
    recommend_resolution(upload)
    
    return true
end

function handle_data_request()
    log_message("SPEEDTEST handle_data_request() started")
    
    local data = {}
    data.timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
    data.device_name = DEVICE_NAME
    
    local cmd
    local use_simple = false
    
    if command_exists("speedtest-cli") then
        cmd = "timeout 90 speedtest-cli --simple 2>&1"
        use_simple = true
    elseif command_exists("speedtest") then
        cmd = "echo y | timeout 90 speedtest 2>&1"
        use_simple = false
    else
        data.error = "speedtest_not_installed"
        log_message("SPEEDTEST ERROR: speedtest-cli not available")
        return data
    end
    
    local handle = io.popen(cmd)
    if not handle then
        data.error = "failed_to_execute"
        log_message("SPEEDTEST ERROR: Failed to execute speedtest")
        return data
    end
    
    local result = handle:read("*a")
    local success = handle:close()
    
    if not result or result == "" then
        data.error = "speedtest_timeout"
        log_message("SPEEDTEST ERROR: Speedtest returned no output (timeout or network issue)")
        return data
    end
    
    if result:match("timed out") or result:match("[Ee]rror") then
        data.error = "speedtest_failed"
        log_message("SPEEDTEST ERROR: Speedtest execution failed")
        log_message("Raw output: " .. tostring(result))
        return data
    end
    
    local upload, download, ping
    
    if use_simple then
        upload = result:match("[Uu]pload:%s*([%d%.]+)")
        download = result:match("[Dd]ownload:%s*([%d%.]+)")
        ping = result:match("[Pp]ing:%s*([%d%.]+)")
    else
        local upload_str, upload_unit = result:match(".*Average upload speed is ([%d%.]+)([kmKM]bps)")
        local download_str, download_unit = result:match(".*Average download speed is ([%d%.]+)([kmKM]bps)")
        
        if upload_str then
            upload = tonumber(upload_str)
            if upload_unit:lower():match("^k") then
                upload = upload / 1000
            end
        end
        
        if download_str then
            download = tonumber(download_str)
            if download_unit:lower():match("^k") then
                download = download / 1000
            end
        end
        
        ping = result:match("[Ll]atency:%s*([%d%.]+)") or result:match("[Pp]ing:%s*([%d%.]+)")
    end
    
    if not upload then
        data.error = "parse_failed"
        log_message("SPEEDTEST ERROR: Could not parse upload speed")
        log_message("Raw output: " .. tostring(result))
        return data
    end
    
    upload = tonumber(upload) or upload
    download = tonumber(download) or download or 0
    ping = tonumber(ping) or 0
    
    data.download_mbps = download
    data.upload_mbps = upload
    data.ping_ms = ping
    data.recommended_resolution = get_resolution_recommendation(upload)
    
    log_message(string.format("SPEEDTEST Results: Download=%.2fMbps, Upload=%.2fMbps, Ping=%.2fms, Recommendation=%s", 
                              download, upload, ping, data.recommended_resolution))
    
    log_message("SPEEDTEST handle_data_request() finished")
    
    return data
end

local function table_to_json(t)
    local json_parts = {}
    for k, v in pairs(t) do
        local key = '"' .. tostring(k) .. '"'
        local value
        if type(v) == "string" then
            value = '"' .. v:gsub('"', '\\"') .. '"'
        elseif type(v) == "number" then
            value = tostring(v)
        elseif type(v) == "boolean" then
            value = tostring(v)
        else
            value = '"' .. tostring(v) .. '"'
        end
        table.insert(json_parts, key .. ":" .. value)
    end
    return "{" .. table.concat(json_parts, ",") .. "}"
end

local function run_speedtest_json()
    local original_print = print
    print = function() end
    
    local data = handle_data_request()
    
    print = original_print
    
    print(table_to_json(data))
    
    return data.error == nil
end

local function send_to_elk(elk_url, elk_user, elk_pass)
    log_message("Sending speedtest data to ELK: " .. elk_url)
    
    local data = handle_data_request()
    
    if data.error then
        log_elk_send("FAILED", "Speedtest error: " .. data.error, elk_url)
        log_message("ELK send failed: Speedtest error - " .. data.error)
        return false
    end
    
    local json_data = table_to_json(data)
    
    local temp_file = "/tmp/speedtest_elk_temp.json"
    local tf = io.open(temp_file, "w")
    if not tf then
        log_elk_send("FAILED", "Could not create temp file", elk_url)
        log_message("ELK send failed: Could not create temp file")
        return false
    end
    tf:write(json_data)
    tf:close()
    
    local auth_param = ""
    if elk_user and elk_pass then
        auth_param = string.format("-u %s:%s ", elk_user, elk_pass)
    end
    
    local curl_cmd = string.format(
        "curl -s -w '\\n%%{http_code}' %s-XPOST '%s' -H 'Content-Type: application/json' -d @%s 2>&1",
        auth_param, elk_url, temp_file
    )
    
    local handle = io.popen(curl_cmd)
    if not handle then
        log_elk_send("FAILED", "Could not execute curl command", elk_url)
        log_message("ELK send failed: Could not execute curl")
        os.remove(temp_file)
        return false
    end
    
    local result = handle:read("*a")
    handle:close()
    
    local http_code = result:match("(%d+)%s*$")
    
    os.remove(temp_file)
    
    if http_code and (http_code == "200" or http_code == "201") then
        log_elk_send("SUCCESS", "HTTP " .. http_code .. " - Upload: " .. data.upload_mbps .. "Mbps, Res: " .. data.recommended_resolution, elk_url)
        log_message("ELK send successful: HTTP " .. http_code)
        return true
    else
        local error_msg = "HTTP " .. (http_code or "unknown") .. " - " .. result:sub(1, 100)
        log_elk_send("FAILED", error_msg, elk_url)
        log_message("ELK send failed: " .. error_msg)
        return false
    end
end

local function main()
    local mode = arg[1]
    
    print("========================================")
    print("Teltonika Speedtest Monitor (Lua)")
    print("========================================")
    print("Log file: " .. LOG_FILE)
    print("Interval: " .. INTERVAL .. " seconds (" .. math.floor(INTERVAL / 60) .. " minutes)")
    print("")
    
    rotate_log()
    log_message("=== Speedtest Monitor Started ===")
    
    if not check_install_speedtest() then
        log_message("Cannot proceed without speedtest-cli")
        os.exit(1)
    end
    
    log_message("Running initial speedtest...")
    run_speedtest()
    
    if mode == "--once" then
        log_message("Single run complete (--once flag)")
        os.exit(0)
    end
    
    if mode == "--daemon" then
        log_message("Running in daemon mode (interval: " .. INTERVAL .. "s)")
        while true do
            os.execute("sleep " .. INTERVAL)
            rotate_log()
            run_speedtest()
        end
    elseif mode == "--service" then
        log_message("Running in service mode (calling handle_data_request)")
        print("")
        print("=== SERVICE MODE ===")
        local result = handle_data_request()
        print("Results:")
        for k, v in pairs(result) do
            print(string.format("  %s = %s", k, tostring(v)))
        end
        os.exit(0)
    elseif mode == "--json" then
        run_speedtest_json()
        os.exit(0)
    elseif mode == "--elk" then
        local elk_url = arg[2]
        local elk_user = arg[3]
        local elk_pass = arg[4]
        
        if not elk_url then
            print("ERROR: ELK URL required")
            print("")
            print("Usage:")
            print("  lua " .. arg[0] .. " --elk <URL> [username] [password]")
            print("")
            print("Examples:")
            print("  lua " .. arg[0] .. " --elk http://192.168.1.100:9200/speedtest-index/_doc")
            print("  lua " .. arg[0] .. " --elk http://192.168.1.100:9200/speedtest-index/_doc elastic changeme")
            os.exit(1)
        end
        
        local success = send_to_elk(elk_url, elk_user, elk_pass)
        os.exit(success and 0 or 1)
    else
        print("")
        print("Single test complete.")
        print("")
        print("Usage:")
        print("  For continuous monitoring:")
        print("    lua " .. arg[0] .. " --daemon &")
        print("")
        print("  For single test:")
        print("    lua " .. arg[0] .. " --once")
        print("")
        print("  For service mode (Data to Server):")
        print("    lua " .. arg[0] .. " --service")
        print("")
        print("  For JSON output (ELK integration):")
        print("    lua " .. arg[0] .. " --json")
        print("")
        print("  For direct ELK send with logging:")
        print("    lua " .. arg[0] .. " --elk <URL> [user] [pass]")
        print("")
        print("  Check ELK send log:")
        print("    cat /tmp/speedtest_elk_send.log")
    end
end

if arg and arg[0] and arg[0]:match("teltonika_speedtest_monitor") then
    main()
end
