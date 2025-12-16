#!/usr/bin/env lua

function handle_data_request()
  local t = os.date("!%Y-%m-%dT%H:%M:%SZ")

  -- log to our own file so we know this was called
  local f = io.open("/tmp/lua_script_status.log", "a")
  if f then
    f:write(t .. " : SOLAR TEST handle_data_request() called\n")
    f:close()
  end

  -- return a simple table for JSON encoding
  local data = {
    timestamp   = t,
    device_name = "Teltonika01",
    test        = "solar_minimal"
  }

  return data
end