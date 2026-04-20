-- Teltonika Network Speed Monitor
-- Camera Resolution Recommender

local LOG_FILE = "/tmp/speedtest_monitor.log"
local ELK_LOG_FILE = "/tmp/speedtest_elk_send.log"
local STATE_FILE = "/tmp/speedtest_state.txt"
local MAX_LOG_SIZE = 200000
local MAX_ELK_LOG_RECORDS = 50
-- Used only when running with --daemon. In Data to Server mode,
-- Teltonika scheduler controls execution interval.
local DAEMON_INTERVAL = 1800
local DEVICE_NAME = "B027"

-- Number of cameras managed by this router (adjust per site)
local NUM_CAMERAS = 2

-- Estimated upload bitrate consumed per camera at each resolution (Mbps)
local CAMERA_BITRATE = {
    ["3840x2160"] = 10.0,  -- 4K: ~10 Mbps per camera
    ["1080P"]     = 5.0,   -- 1080P: ~5 Mbps per camera
    ["720P"]      = 2.5,   -- 720P: ~2.5 Mbps per camera
}

-- Headroom to keep free above camera load (Mbps)
local HEADROOM_MBPS = 3.0

-- Consecutive cycles required before upgrading resolution (anti-flap)
local UPGRADE_CYCLES_REQUIRED = 2

-- Consecutive cycles required before downgrading (1 = immediate for safety)
local DOWNGRADE_CYCLES_REQUIRED = 1

-- Resolution tier order (1=lowest, 3=highest)
local RESOLUTION_TIERS = { "720P", "1080P", "3840x2160" }

local function get_tier(resolution)
    for i, r in ipairs(RESOLUTION_TIERS) do
        if r == resolution then return i end
    end
    return 1  -- default to lowest if unknown
end

local function read_state()
    local state = { resolution = "1080P", consecutive_better = 0, consecutive_worse = 0 }
    local f = io.open(STATE_FILE, "r")
    if f then
        for line in f:lines() do
            local k, v = line:match("^(%w+)=(.+)$")
            if k == "resolution" then state.resolution = v
            elseif k == "consecutive_better" then state.consecutive_better = tonumber(v) or 0
            elseif k == "consecutive_worse" then state.consecutive_worse = tonumber(v) or 0
            end
        end
        f:close()
    end
    return state
end

local function write_state(state)
    local f = io.open(STATE_FILE, "w")
    if f then
        f:write("resolution=" .. state.resolution .. "\n")
        f:write("consecutive_better=" .. tostring(state.consecutive_better) .. "\n")
        f:write("consecutive_worse=" .. tostring(state.consecutive_worse) .. "\n")
        f:close()
    end
end

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

local function recommend_resolution(upload_speed, new_resolution, estimated_capacity, current_resolution)
    print("")
    print("================================================")
    print("CAMERA RESOLUTION RECOMMENDATION")
    print("================================================")
    print(string.format("Measured Upload (headroom only): %.2f Mbps", upload_speed))
    print(string.format("Current Resolution: %s", current_resolution))
    print(string.format("Estimated Camera Load: %.2f Mbps (%d cameras)", NUM_CAMERAS * (CAMERA_BITRATE[current_resolution] or 5.0), NUM_CAMERAS))
    print(string.format("Estimated Total Capacity: %.2f Mbps", estimated_capacity))
    print(string.format("Recommended: %s", new_resolution))
    print("================================================")
    print("")

    log_message(string.format(
        "RECOMMENDATION: %s (measured=%.2fMbps, capacity=%.2fMbps, current=%s)",
        new_resolution, upload_speed, estimated_capacity, current_resolution))
end

-- Returns the best tier the link can sustain given total estimated capacity
local function best_affordable_resolution(estimated_capacity)
    local best = RESOLUTION_TIERS[1]
    for _, tier in ipairs(RESOLUTION_TIERS) do
        local needed = NUM_CAMERAS * (CAMERA_BITRATE[tier] or 5.0) + HEADROOM_MBPS
        if estimated_capacity >= needed then
            best = tier
        end
    end
    return best
end

-- Main decision function with hysteresis and capacity correction
-- Returns: new_resolution, state (updated), estimated_capacity
local function get_resolution_recommendation(upload_speed)
    local state = read_state()
    local current = state.resolution

    -- Estimated total capacity = measured headroom + camera load at current resolution
    local current_camera_load = NUM_CAMERAS * (CAMERA_BITRATE[current] or 5.0)
    local estimated_capacity = upload_speed + current_camera_load

    local target = best_affordable_resolution(estimated_capacity)
    local current_tier = get_tier(current)
    local target_tier = get_tier(target)

    local new_resolution = current  -- default: no change

    if target_tier > current_tier then
        -- Potential upgrade
        state.consecutive_better = state.consecutive_better + 1
        state.consecutive_worse = 0
        log_message(string.format(
            "HYSTERESIS: Upgrade candidate %s (cycle %d/%d)",
            target, state.consecutive_better, UPGRADE_CYCLES_REQUIRED))
        if state.consecutive_better >= UPGRADE_CYCLES_REQUIRED then
            new_resolution = target
            state.consecutive_better = 0
        end
    elseif target_tier < current_tier then
        -- Potential downgrade
        state.consecutive_worse = state.consecutive_worse + 1
        state.consecutive_better = 0
        log_message(string.format(
            "HYSTERESIS: Downgrade candidate %s (cycle %d/%d)",
            target, state.consecutive_worse, DOWNGRADE_CYCLES_REQUIRED))
        if state.consecutive_worse >= DOWNGRADE_CYCLES_REQUIRED then
            new_resolution = target
            state.consecutive_worse = 0
        end
    else
        -- Stable
        state.consecutive_better = 0
        state.consecutive_worse = 0
    end

    state.resolution = new_resolution
    write_state(state)

    return new_resolution, estimated_capacity
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

    local state = read_state()
    local new_res, estimated_capacity = get_resolution_recommendation(upload)
    recommend_resolution(upload, new_res, estimated_capacity, state.resolution)

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

    local current_state = read_state()
    local new_res, estimated_capacity = get_resolution_recommendation(upload)
    data.recommended_resolution = new_res
    data.estimated_capacity_mbps = estimated_capacity
    data.previous_resolution = current_state.resolution

    log_message(string.format("SPEEDTEST Results: Download=%.2fMbps, Upload=%.2fMbps, Ping=%.2fms, Capacity=%.2fMbps, Recommendation=%s",
                              download, upload, ping, estimated_capacity, data.recommended_resolution))
    
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
        log_message("Running in daemon mode (interval: " .. DAEMON_INTERVAL .. "s)")
        while true do
            os.execute("sleep " .. DAEMON_INTERVAL)
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
        print("    lua " .. arg[0] .. " --daemon &    (uses DAEMON_INTERVAL)")
        print("")
        print("  For single test:")
        print("    lua " .. arg[0] .. " --once")
        print("")
        print("  For service mode (Data to Server):")
        print("    lua " .. arg[0] .. " --service")
        print("    Note: interval is managed by Teltonika Data to Server")
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
