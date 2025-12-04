--[[
Modbus RTU-over-TCP to Standard Modbus TCP Gateway
Runs on Teltonika TRB901
Translates between NE2-D11's protocol and TRB901's Modbus TCP Client
]]

local socket = require("socket")

-- Configuration
local NE2_HOST = "192.168.1.7"
local NE2_PORT = 502
local NE2_SLAVE_ID = 1
local NE2_TIMEOUT = 3

local GATEWAY_HOST = "127.0.0.1"  -- Localhost
local GATEWAY_PORT = 5502         -- Different port from NE2
local MAX_CLIENTS = 5

-- ============== CRC16 Modbus ==============

local function crc16_modbus(data)
    local crc = 0xFFFF
    for i = 1, #data do
        local b = string.byte(data, i)
        crc = crc ~ b
        for j = 1, 8 do
            if (crc & 0x0001) ~= 0 then
                crc = (crc >> 1) ~ 0xA001
            else
                crc = crc >> 1
            end
        end
    end
    return crc
end

-- ============== Modbus RTU Protocol (for NE2) ==============

local function build_rtu_request(slave_id, func, addr, qty)
    -- Pack: Slave ID, Function, Address (16-bit), Quantity (16-bit)
    local pdu = string.pack(">BBHH", slave_id, func, addr, qty)
    local crc = crc16_modbus(pdu)
    return pdu .. string.pack("<H", crc)
end

local function parse_rtu_response(resp, qty)
    if #resp < 5 then
        return nil, "Response too short: " .. #resp .. " bytes"
    end
    
    local slave_id, func, byte_count = string.unpack(">BBB", resp)
    
    -- Check for exception
    if (func & 0x80) ~= 0 then
        local error_code = string.byte(resp, 3)
        return nil, string.format("Modbus exception: func=0x%02X, error=0x%02X", func, error_code)
    end
    
    -- Validate byte count
    local expected = qty * 2
    if byte_count ~= expected then
        return nil, string.format("Byte count mismatch: got %d, expected %d", byte_count, expected)
    end
    
    -- Extract register data (without CRC)
    local data = string.sub(resp, 4, 3 + byte_count)
    
    return func, data
end

local function query_ne2(func, addr, qty)
    local client = socket.tcp()
    client:settimeout(NE2_TIMEOUT)
    
    local ok, err = client:connect(NE2_HOST, NE2_PORT)
    if not ok then
        client:close()
        return nil, "Cannot connect to NE2: " .. tostring(err)
    end
    
    -- Send RTU request
    local req = build_rtu_request(NE2_SLAVE_ID, func, addr, qty)
    local bytes_sent, send_err = client:send(req)
    if not bytes_sent then
        client:close()
        return nil, "Send error: " .. tostring(send_err)
    end
    
    -- Receive RTU response
    local resp, recv_err = client:receive(5 + qty * 2 + 2)
    client:close()
    
    if not resp then
        return nil, "Receive error: " .. tostring(recv_err)
    end
    
    -- Parse response
    local func_resp, data = parse_rtu_response(resp, qty)
    if not func_resp then
        return nil, data  -- data contains error message
    end
    
    return data
end

-- ============== Modbus TCP Protocol (Standard) ==============

local function parse_modbus_tcp_request(data)
    if #data < 12 then
        return nil, "Invalid Modbus TCP request: " .. #data .. " bytes"
    end
    
    -- MBAP Header
    local trans_id = string.unpack(">H", data, 1)
    local proto_id = string.unpack(">H", data, 3)
    local length = string.unpack(">H", data, 5)
    local unit_id = string.byte(data, 7)
    
    -- PDU
    local func = string.byte(data, 8)
    local start_addr = string.unpack(">H", data, 9)
    local qty = string.unpack(">H", data, 11)
    
    if proto_id ~= 0 then
        return nil, "Invalid protocol ID: " .. proto_id
    end
    
    return trans_id, unit_id, func, start_addr, qty
end

local function build_modbus_tcp_response(trans_id, unit_id, func, data)
    local length = 3 + #data  -- Unit ID + Function + Byte Count + Data
    
    -- MBAP Header
    local mbap = string.pack(">HHHB", trans_id, 0, length, unit_id)
    
    -- PDU
    local byte_count = #data
    local pdu = string.pack(">BB", func, byte_count) .. data
    
    return mbap .. pdu
end

local function build_modbus_tcp_error(trans_id, unit_id, func, error_code)
    local length = 3
    
    -- MBAP Header
    local mbap = string.pack(">HHHB", trans_id, 0, length, unit_id)
    
    -- Exception PDU
    local exception_func = func | 0x80
    local pdu = string.pack(">BB", exception_func, error_code)
    
    return mbap .. pdu
end

-- ============== Client Handler ==============

local function handle_client(client_sock, client_addr)
    print(string.format("[%s] Client connected: %s", os.date("%Y-%m-%d %H:%M:%S"), client_addr))
    
    client_sock:settimeout(60)  -- 60 second timeout for client
    
    while true do
        -- Receive Modbus TCP request
        local tcp_req, err = client_sock:receive(12)  -- Minimum MBAP + PDU header
        if not tcp_req then
            if err ~= "closed" then
                print(string.format("[%s] Receive error from %s: %s", os.date("%Y-%m-%d %H:%M:%S"), client_addr, err))
            end
            break
        end
        
        -- Parse request
        local trans_id, unit_id, func, start_addr, qty = parse_modbus_tcp_request(tcp_req)
        if not trans_id then
            print(string.format("[%s] Parse error: %s", os.date("%Y-%m-%d %H:%M:%S"), unit_id))
            break
        end
        
        print(string.format("[%s] Request: func=0x%02X, addr=0x%04X, qty=%d", 
            os.date("%Y-%m-%d %H:%M:%S"), func, start_addr, qty))
        
        -- Forward to NE2-D11
        local register_data, ne2_err = query_ne2(func, start_addr, qty)
        
        if register_data then
            -- Build and send success response
            local tcp_resp = build_modbus_tcp_response(trans_id, unit_id, func, register_data)
            client_sock:send(tcp_resp)
            print(string.format("[%s] Response sent: %d bytes", os.date("%Y-%m-%d %H:%M:%S"), #register_data))
        else
            -- Send error response
            print(string.format("[%s] NE2 error: %s", os.date("%Y-%m-%d %H:%M:%S"), ne2_err))
            local error_resp = build_modbus_tcp_error(trans_id, unit_id, func, 0x04)  -- Slave device failure
            client_sock:send(error_resp)
        end
    end
    
    client_sock:close()
    print(string.format("[%s] Client disconnected: %s", os.date("%Y-%m-%d %H:%M:%S"), client_addr))
end

-- ============== Main Server ==============

local function main()
    -- Test connection to NE2-D11
    print("Testing connection to NE2-D11...")
    local test_data, test_err = query_ne2(0x04, 0x3100, 1)
    if test_data then
        print(string.format("✓ NE2-D11 connection OK (test data: %d bytes)", #test_data))
    else
        print("✗ Cannot connect to NE2-D11: " .. tostring(test_err))
        print("Please check NE2_HOST and NE2_PORT settings")
        return
    end
    
    -- Start gateway server
    local server = socket.tcp()
    server:setreuseaddr(true)
    
    local ok, err = server:bind(GATEWAY_HOST, GATEWAY_PORT)
    if not ok then
        print("Cannot bind to " .. GATEWAY_HOST .. ":" .. GATEWAY_PORT .. ": " .. tostring(err))
        return
    end
    
    server:listen(MAX_CLIENTS)
    server:settimeout(1)  -- 1 second timeout for accept (allows clean shutdown)
    
    print("Modbus Gateway started")
    print(string.format("Listening on %s:%d", GATEWAY_HOST, GATEWAY_PORT))
    print(string.format("Forwarding to NE2-D11 at %s:%d", NE2_HOST, NE2_PORT))
    print("Ready to accept connections from TRB901 Modbus client...")
    
    while true do
        local client_sock, accept_err = server:accept()
        if client_sock then
            local client_ip, client_port = client_sock:getpeername()
            local client_addr = string.format("%s:%d", client_ip or "unknown", client_port or 0)
            
            -- Handle client in separate coroutine (Lua doesn't have threads, but coroutines work)
            -- For simplicity, handle synchronously (one client at a time)
            handle_client(client_sock, client_addr)
        elseif accept_err ~= "timeout" then
            print("Accept error: " .. tostring(accept_err))
            break
        end
    end
    
    server:close()
    print("Gateway stopped")
end

-- Run main
local status, err = pcall(main)
if not status then
    print("Fatal error: " .. tostring(err))
end