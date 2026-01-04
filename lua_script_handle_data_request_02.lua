#!/usr/bin/env lua

local socket = require("socket")

ip = "192.168.198.230"
port = 502

-- Log helper with rotation
local LOG_FILE = "/tmp/lua_script_status.log"
local MAX_LOG_SIZE = 100000  -- 100KB max
local function log_write(message)
  local lf = io.open(LOG_FILE, "a")
  if lf then
    -- Check file size and rotate if needed
    local current_pos = lf:seek("end")
    if current_pos and current_pos > MAX_LOG_SIZE then
      lf:close()
      -- Keep only last 50KB
      os.execute("tail -c 50000 " .. LOG_FILE .. " > " .. LOG_FILE .. ".tmp && mv " .. LOG_FILE .. ".tmp " .. LOG_FILE)
      lf = io.open(LOG_FILE, "a")
    end
    if lf then
      lf:write(os.date("!%Y-%m-%dT%H:%M:%SZ") .. " : " .. message .. "\n")
      lf:close()
    end
  end
end

-- Helpers
local function bxor(a,b)
  local r,v = 0,1
  while a>0 or b>0 do
    if (a%2) ~= (b%2) then r = r + v end
    a = math.floor(a/2)
    b = math.floor(b/2)
    v = v * 2
  end
  return r
end

local function crc(d)
  local c = 0xFFFF
  for i = 1, #d do
    c = bxor(c, d:byte(i))
    for _ = 1, 8 do
      if c % 2 == 1 then
        c = bxor(math.floor(c / 2), 0xA001)
      else
        c = math.floor(c / 2)
      end
    end
  end
  return c
end

local function u16(p,i) return p:byte(i) * 256 + p:byte(i+1) end
local function s16(p,i)
  local v = u16(p,i)
  if v >= 32768 then v = v - 65536 end
  return v
end
local function u32(p,i) return u16(p,i) + u16(p,i+2) * 65536 end
local function s32(p,i)
  local v = u32(p,i)
  if v >= 2147483648 then v = v - 4294967296 end
  return v
end

-- function to read Modbus registers
local function rd(sock, a, q, fc)
  fc = fc or 4
  local pdu = string.char(1, fc, math.floor(a/256), a%256, 0, q)
  local cr = crc(pdu)
  sock:send(pdu .. string.char(cr%256, math.floor(cr/256)))
  local len = 5 + q * 2
  local p = ""
  while #p < len do
    local chunk = sock:receive(len - #p)
    if not chunk then break end
    p = p .. chunk
  end
  return p
end

-- REQUIRED ENTRY POINT FOR SOLAR
function handle_data_request()
  log_write("SOLAR handle_data_request() started")

  local data = {}
  data.timestamp   = os.date("!%Y-%m-%dT%H:%M:%SZ")
  data.device_name = "Teltonika_B080"

  -- connect to Modbus TCP
  local s = socket.tcp()
  s:settimeout(1)
  local ok, err = s:connect(ip, port)
  if not ok then
    data.error = "connect_failed: " .. tostring(err)
    log_write("SOLAR connect failed: " .. tostring(err))
    return data
  end

  -- === RATED DATA ===
  local p = rd(s, 0x3000, 9)
  if p and #p > 20 then
    data.PV_Rated_Voltage   = string.format("%.2fV", u16(p,4)  * 0.01)
    data.PV_Rated_Current   = string.format("%.2fA", u16(p,6)  * 0.01)
    data.PV_Rated_Power     = string.format("%.2fW", u32(p,8)  * 0.01)
    data.Batt_Rated_Voltage = string.format("%.2fV", u16(p,12) * 0.01)
    data.Batt_Rated_Current = string.format("%.2fA", u16(p,14) * 0.01)
    data.Batt_Rated_Power   = string.format("%.2fW", u32(p,16) * 0.01)
    data.Charging_Mode      = tostring(u16(p,20))
  end

  p = rd(s, 0x300E, 1)
  if p and #p > 4 then
    data.Load_Rated_Current = string.format("%.2fA", u16(p,4) * 0.01)
  end

  -- === REALTIME DATA ===
  p = rd(s, 0x3100, 8)
  if p and #p > 18 then
    data.PV_Voltage          = string.format("%.2fV", u16(p,4)  * 0.01)
    data.PV_Current          = string.format("%.2fA", u16(p,6)  * 0.01)
    data.PV_Power            = string.format("%.2fW", u32(p,8)  * 0.01)
    data.Batt_Charge_Voltage = string.format("%.2fV", u16(p,12) * 0.01)
    data.Batt_Charge_Current = string.format("%.2fA", u16(p,14) * 0.01)
    data.Batt_Charge_Power   = string.format("%.2fW", u32(p,16) * 0.01)
  end

  p = rd(s, 0x310C, 4)
  if p and #p > 10 then
    data.Load_Voltage = string.format("%.2fV", u16(p,4) * 0.01)
    data.Load_Current = string.format("%.2fA", u16(p,6) * 0.01)
    data.Load_Power   = string.format("%.2fW", u32(p,8) * 0.01)
  end

  p = rd(s, 0x3110, 3)
  if p and #p > 8 then
    data.Battery_Temp    = string.format("%.2fC", s16(p,4) * 0.01)
    data.Device_Temp     = string.format("%.2fC", s16(p,6) * 0.01)
    data.Components_Temp = string.format("%.2fC", s16(p,8) * 0.01)
  end

  p = rd(s, 0x311A, 4)
  if p and #p > 10 then
    data.SOC                = tostring(u16(p,4)) .. "%"
    data.Remote_Batt_Temp   = string.format("%.2fC", s16(p,6) * 0.01)
    data.System_RatedVoltage= string.format("%.2fV", u16(p,10) * 0.01)
  end

  -- === STATUS ===
  p = rd(s, 0x3200, 2)
  if p and #p > 6 then
    data.Battery_Status = tostring(u16(p,4))
    data.Charger_Status = tostring(u16(p,6))
  end

  -- === STATISTICS ===
  p = rd(s, 0x3300, 4)
  if p and #p > 10 then
    data.Max_PV_Voltage_Today   = string.format("%.2fV", u16(p,4)  * 0.01)
    data.Min_PV_Voltage_Today   = string.format("%.2fV", u16(p,6)  * 0.01)
    data.Max_Batt_Voltage_Today = string.format("%.2fV", u16(p,8)  * 0.01)
    data.Min_Batt_Voltage_Today = string.format("%.2fV", u16(p,10) * 0.01)
  end

  p = rd(s, 0x3304, 8)
  if p and #p > 18 then
    data.Consumed_Today = string.format("%.2fkWh", u32(p,4)  * 0.01)
    data.Consumed_Month = string.format("%.2fkWh", u32(p,8)  * 0.01)
    data.Consumed_Year  = string.format("%.2fkWh", u32(p,12) * 0.01)
    data.Consumed_Total = string.format("%.2fkWh", u32(p,16) * 0.01)
  end

  p = rd(s, 0x330C, 8)
  if p and #p > 18 then
    data.Generated_Today = string.format("%.2fkWh", u32(p,4)  * 0.01)
    data.Generated_Month = string.format("%.2fkWh", u32(p,8)  * 0.01)
    data.Generated_Year  = string.format("%.2fkWh", u32(p,12) * 0.01)
    data.Generated_Total = string.format("%.2fkWh", u32(p,16) * 0.01)
  end

  p = rd(s, 0x3314, 2)
  if p and #p > 6 then
    data.CO2_Reduction = string.format("%.2fTon", u32(p,4) * 0.01)
  end

  p = rd(s, 0x331A, 4)
  if p and #p > 10 then
    data.Battery_Net_Voltage = string.format("%.2fV", u16(p,4) * 0.01)
    data.Battery_Net_Current = string.format("%.2fA", s32(p,6) * 0.01)
  end

  p = rd(s, 0x331D, 2)
  if p and #p > 6 then
    data.Battery_Temp2 = string.format("%.2fC", s16(p,4) * 0.01)
    data.Ambient_Temp  = string.format("%.2fC", s16(p,6) * 0.01)
  end

  -- === SETTINGS ===
  p = rd(s, 0x9000, 15, 3)
  if p and #p > 32 then
    data.Battery_Type               = tostring(u16(p,4))
    data.Battery_Capacity           = tostring(u16(p,6)) .. "Ah"
    data.Temp_Compensation          = string.format("%.2fmV/C/2V", u16(p,8)  * 0.01)
    data.High_Volt_Disconnect       = string.format("%.2fV", u16(p,10) * 0.01)
    data.Charging_Limit_Voltage     = string.format("%.2fV", u16(p,12) * 0.01)
    data.Over_Volt_Reconnect        = string.format("%.2fV", u16(p,14) * 0.01)
    data.Equalize_Voltage           = string.format("%.2fV", u16(p,16) * 0.01)
    data.Boost_Voltage              = string.format("%.2fV", u16(p,18) * 0.01)
    data.Float_Voltage              = string.format("%.2fV", u16(p,20) * 0.01)
    data.Boost_Reconnect_Voltage    = string.format("%.2fV", u16(p,22) * 0.01)
    data.Low_Volt_Reconnect         = string.format("%.2fV", u16(p,24) * 0.01)
    data.Under_Volt_Recover         = string.format("%.2fV", u16(p,26) * 0.01)
    data.Under_Volt_Warning         = string.format("%.2fV", u16(p,28) * 0.01)
    data.Low_Volt_Disconnect        = string.format("%.2fV", u16(p,30) * 0.01)
    data.Discharge_Limit_Voltage    = string.format("%.2fV", u16(p,32) * 0.01)
  end

  p = rd(s, 0x9013, 3, 3)
  if p and #p > 8 then
    data.RTC = string.format(
      "20%d-%02d-%02d %02d:%02d:%02d",
      p:byte(9), p:byte(8), p:byte(7),
      p:byte(6), p:byte(5), p:byte(4)
    )
  end

  p = rd(s, 0x9016, 7, 3)
  if p and #p > 16 then
    data.Equalize_Cycle          = tostring(u16(p,4))  .. " days"
    data.Batt_Temp_Warn_Upper    = string.format("%.2fC", u16(p,6)  * 0.01)
    data.Batt_Temp_Warn_Lower    = string.format("%.2fC", u16(p,8)  * 0.01)
    data.Controller_Temp_Upper   = string.format("%.2fC", u16(p,10) * 0.01)
    data.Controller_Temp_Recover = string.format("%.2fC", u16(p,12) * 0.01)
    data.Components_Temp_Upper   = string.format("%.2fC", u16(p,14) * 0.01)
    data.Components_Temp_Recover = string.format("%.2fC", u16(p,16) * 0.01)
  end

  p = rd(s, 0x901D, 5, 3)
  if p and #p > 12 then
    data.Line_Impedance        = string.format("%.2fmOhm", u16(p,4)  * 0.01)
    data.Night_Threshold_Volt  = string.format("%.2fV",    u16(p,6)  * 0.01)
    data.Night_Delay_Time      = tostring(u16(p,8))  .. "min"
    data.Day_Threshold_Volt    = string.format("%.2fV",    u16(p,10) * 0.01)
    data.Day_Delay_Time        = tostring(u16(p,12)) .. "min"
  end

  p = rd(s, 0x903D, 3, 3)
  if p and #p > 8 then
    data.Load_Control_Mode = tostring(u16(p,4))
    data.Working_Time1     = string.format("%dh%dm",
      math.floor(u16(p,6)/256), u16(p,6)%256
    )
    data.Working_Time2     = string.format("%dh%dm",
      math.floor(u16(p,8)/256), u16(p,8)%256
    )
  end

  p = rd(s, 0x9065, 1, 3)
  if p and #p > 4 then
    data.Night_Length = string.format("%dh%dm",
      math.floor(u16(p,4)/256), u16(p,4)%256
    )
  end

  p = rd(s, 0x9067, 1, 3)
  if p and #p > 4 then
    data.Battery_Rated_Voltage_Code = tostring(u16(p,4))
  end

  p = rd(s, 0x906B, 4, 3)
  if p and #p > 10 then
    data.Equalize_Duration   = tostring(u16(p,4))  .. "min"
    data.Boost_Duration      = tostring(u16(p,6))  .. "min"
    data.Discharge_Percentage= string.format("%.2f%%", u16(p,8)  * 0.01)
    data.Charge_Percentage   = string.format("%.2f%%", u16(p,10) * 0.01)
  end

  p = rd(s, 0x9070, 1, 3)
  if p and #p > 4 then
    data.Management_Mode = tostring(u16(p,4))
  end

  s:close()

  log_write("SOLAR handle_data_request() finished")

  return data
end