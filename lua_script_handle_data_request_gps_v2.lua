#!/usr/bin/env lua

-- GPS -> JSON for Logstash (Teltonika RUT906)
-- Uses /usr/sbin/gpsctl
-- Output matches your Logstash mapping:
--   [json_data][input1][latitude], [json_data][input1][longitude]
--
-- IMPORTANT:
-- gpsctl -t on this device appears to be "local-epoch" (UTC+offset), so DO NOT
-- generate a "Z" timestamp from it.
-- Instead we use gpsctl -e (local datetime) for input1.timestamp (no Z),
-- and keep timestamp_epoch as a raw number for reference.

local LOG_FILE = "/tmp/lua_script_gps_status.log"
local MAX_LOG_SIZE = 100000  -- 100KB max

-- =========================
-- LOG helper with rotation
-- =========================
local function log_write(message)
  local lf = io.open(LOG_FILE, "a")
  if lf then
    local current_pos = lf:seek("end")
    if current_pos and current_pos > MAX_LOG_SIZE then
      lf:close()
      -- Keep only last 50KB
      os.execute("tail -c 50000 " .. LOG_FILE .. " > " .. LOG_FILE .. ".tmp && mv " .. LOG_FILE .. ".tmp " .. LOG_FILE)
      lf = io.open(LOG_FILE, "a")
    end
    if lf then
      -- use system UTC for log prefix (safe)
      local ts = (io.popen("date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null"):read("*l")) or os.date("%Y-%m-%dT%H:%M:%SZ") .. "Z"
      lf:write(ts .. " : " .. message .. "\n")
      lf:close()
    end
  end
end

local function exec_read(cmd)
  local p = io.popen(cmd .. " 2>/dev/null")
  if not p then return nil end
  local out = p:read("*a")
  p:close()
  if not out or out == "" then return nil end
  return out
end

local function iso_now_utc()
  local out = exec_read("date -u +%Y-%m-%dT%H:%M:%SZ")
  if not out then
    return os.date("%Y-%m-%dT%H:%M:%SZ") .. "Z"
  end
  return out:gsub("%s+$","")
end

local function to_number(s)
  if s == nil then return nil end
  if type(s) == "number" then return s end
  s = tostring(s):gsub(",", ".")
  return tonumber(s)
end

-- gpsctl often prints latitude on first line and the requested value on last line.
local function gpsctl_value(flag)
  local out = exec_read("/usr/sbin/gpsctl " .. flag)
  if not out then return nil end

  local lines = {}
  for line in out:gmatch("[^\r\n]+") do
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" then table.insert(lines, line) end
  end

  if #lines == 0 then return nil end
  if #lines == 1 then return lines[1] end
  return lines[#lines]
end

-- =========================
-- REQUIRED ENTRY POINT
-- =========================
function handle_data_request()
  log_write("GPS handle_data_request() started")

  local lat = to_number(gpsctl_value("-i"))
  local lon = to_number(gpsctl_value("-x"))

  if not lat or not lon then
    local out = {
      timestamp = iso_now_utc(),
      device_name = "RUT906",
      error = "no_latlon_from_gpsctl"
    }
    log_write("GPS error: " .. out.error)
    return out
  end

  -- Local datetime from GPS (recommended for Logstash date filter with timezone Asia/Jerusalem)
  local dt_local = gpsctl_value("-e")  -- "YYYY-MM-DD HH:MM:SS" (string)
  local ts_local_iso = dt_local and (dt_local:gsub(" ", "T")) or nil  -- NO "Z" here

  -- Keep raw epoch only as reference (do not claim it's UTC)
  local ts_epoch = to_number(gpsctl_value("-t"))

  local speed_ms = to_number(gpsctl_value("-v"))       -- m/s
  local speed_kmh = speed_ms and (speed_ms * 3.6) or nil
  local speed_kn = to_number(gpsctl_value("-S"))       -- knots

  local sats = to_number(gpsctl_value("-p"))
  local angle = to_number(gpsctl_value("-g"))
  local alt_m = to_number(gpsctl_value("-a"))
  local acc = to_number(gpsctl_value("-u"))

  local fix_status = to_number(gpsctl_value("-s"))
  local fix_quality = to_number(gpsctl_value("-F"))
  local fix_set_mode = to_number(gpsctl_value("-f"))
  local fix_curr_mode = to_number(gpsctl_value("-G"))

  local pdop = to_number(gpsctl_value("-P"))
  local hdop = to_number(gpsctl_value("-H"))
  local vdop = to_number(gpsctl_value("-V"))

  local tmg_true = to_number(gpsctl_value("-r"))
  local tmg_mag = to_number(gpsctl_value("-R"))

  local data = {
    -- Keep a top-level timestamp for convenience:
    -- prefer GPS local time (no Z), else fall back to system UTC.
    timestamp = ts_local_iso or iso_now_utc(),
    device_name = "RUT906",
    input1 = {
      latitude = lat,
      longitude = lon,

      -- Primary GPS time fields:
      timestamp = ts_local_iso or nil,         -- local ISO, NO Z
      datetime = dt_local or nil,              -- "YYYY-MM-DD HH:MM:SS"
      timestamp_epoch = ts_epoch,              -- raw number (may be local-epoch)

      speed = speed_ms,
      speed_ms = speed_ms,
      speed_kmh = speed_kmh,
      speed_kn = speed_kn,

      satellites = sats,
      altitude_m = alt_m,
      angle = angle,
      accuracy = acc,

      fix_status = fix_status,
      fix_quality = fix_quality,
      fix_set_mode = fix_set_mode,
      fix_curr_mode = fix_curr_mode,

      pdop = pdop,
      hdop = hdop,
      vdop = vdop,

      tmg_true = tmg_true,
      tmg_mag = tmg_mag
    }
  }

  log_write(string.format(
    "GPS ok lat=%.6f lon=%.6f speed_ms=%s sats=%s datetime=%s",
    lat, lon, tostring(speed_ms), tostring(sats), tostring(dt_local)
  ))
  log_write("GPS handle_data_request() finished")

  return data
end

-- =========================
-- CLI TEST MODE
-- =========================
local function cli_test()
  print("=== LUA GPS SCRIPT CLI TEST MODE (gpsctl) ===")
  print("Timestamp (system UTC): " .. iso_now_utc())
  print("")

  log_write("CLI TEST MODE: Starting GPS test execution")

  local result = handle_data_request()

  print("=== RESULTS ===")
  if result.error then
    print("ERROR: " .. tostring(result.error))
  else
    for k, v in pairs(result) do
      if type(v) == "table" then
        print("  " .. k .. " = { ... }")
        for kk, vv in pairs(v) do
          print(string.format("    %s = %s", kk, tostring(vv)))
        end
      else
        print(string.format("  %s = %s", k, tostring(v)))
      end
    end
  end

  print("")
  print("Log: " .. LOG_FILE)
  print("=== TEST COMPLETE ===")
end

-- Auto-run test if executed directly
if arg and arg[0] and arg[0]:match("lua_script_handle_data_request_gps") then
  cli_test()
end