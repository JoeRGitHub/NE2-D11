# Teltonika Data Collection Scripts

Collection of Lua scripts for monitoring and data collection on Teltonika devices.

## Device

ne2-d11p (Teltonika RUT251)

## Scripts Overview

### 1. Solar Controller Monitoring (`lua_script_handle_data_request_02.lua`)

Monitors Epever/MPPT solar charge controller via Modbus TCP.

**Features:**

- Collects rated data, real-time measurements, statistics
- Reads battery status, charging status, temperatures
- Tracks energy generation and consumption
- Compatible with Teltonika Data to Server service

**Connection:**

- IP: 192.168.198.230
- Port: 502 (Modbus TCP)

### 2. Network Speed Monitor (`teltonika_speedtest_monitor.lua`)

Monitors network speed and recommends camera resolution settings.

**Features:**

- Tests upload/download speeds using built-in speedtest
- Provides camera resolution recommendations based on upload speed
- Auto-confirms speedtest prompts
- Logs results with rotation
- Multiple run modes: CLI, daemon, service

## Installation

### Upload to Teltonika Device

```bash
# Via SCP
scp lua_script_handle_data_request_02.lua root@192.168.198.226:/root/
scp teltonika_speedtest_monitor.lua root@192.168.198.226:/root/

# Or via SSH
ssh root@192.168.198.226
# Then paste the script content
```

## Usage

### Solar Controller Script

**CLI Test Mode (with diagnostics):**

```bash
lua lua_script_handle_data_request_02.lua
```

**For Data to Server Service:**

- Configure in Teltonika Web UI: Services → Data to Server
- Script will export `handle_data_request()` function
- Returns structured data with all solar metrics

**Check logs:**

```bash
tail -f /tmp/lua_script_status.log
```

### Network Speed Monitor

**Single Test:**

```bash
lua teltonika_speedtest_monitor.lua --once
```

**Continuous Monitoring (every 30 min):**

```bash
lua teltonika_speedtest_monitor.lua --daemon &
```

**Service Mode (for Data to Server):**

```bash
lua teltonika_speedtest_monitor.lua --service
```

**JSON Mode (for ELK integration):**

```bash
# Output clean JSON
lua teltonika_speedtest_monitor.lua --json

# Save to file
lua teltonika_speedtest_monitor.lua --json > /tmp/speedtest.json
```

**Check logs:**

```bash
tail -f /tmp/speedtest_monitor.log
```

## ELK (Elasticsearch) Integration

### Send Speedtest Data to Elasticsearch

**Method 1: Direct Send with Logging (Recommended)**

```bash
# Send to ELK with automatic success/failure logging
lua teltonika_speedtest_monitor.lua --elk "http://<IP>:<PORT>/speedtest-index/_doc"

# With authentication
lua teltonika_speedtest_monitor.lua --elk "http://<IP>:<PORT>/speedtest-index/_doc" elastic changeme

# Check send log (last 50 records)
cat /tmp/speedtest_elk_send.log
tail -f /tmp/speedtest_elk_send.log
```

**Method 2: JSON Pipe (Manual)**

```bash
# Run speedtest and send directly to Elasticsearch
lua teltonika_speedtest_monitor.lua --json | \
  curl -u user:"pass" -XPOST "http://<IP>:<PORT>/speedtest-index/_doc" \
  -H 'Content-Type: application/json' \
  -d @-
```

**Method 3: Save and Send (Two-step)**

```bash
# Generate JSON file
lua teltonika_speedtest_monitor.lua --json > /tmp/speedtest.json

# Send to Elasticsearch
curl -u user:"pass" -XPOST "http://<IP>:<PORT>/speedtest-index/_doc" \
  -H 'Content-Type: application/json' \
  -d @/tmp/speedtest.json
```

**Method 4: Scheduled Collection (Cron)**

```bash
# Add to crontab for automatic collection every hour
# Edit crontab: crontab -e
0 * * * * lua /root/teltonika_speedtest_monitor.lua --elk "http://<IP>:<PORT>/speedtest-index/_doc" elastic changeme
```

### ELK Send Log

The script maintains a separate log at `/tmp/speedtest_elk_send.log` that tracks all ELK send attempts:

**Log Format:**

```
Timestamp | Status | Message | ELK URL
```

**Example Log Entries:**

```
2026-01-16T01:00:00Z | SUCCESS | HTTP 201 - Upload: 11.92Mbps, Res: 1080p_high | http://192.168.1.100:9200/speedtest-index/_doc
2026-01-16T02:00:00Z | FAILED | HTTP 401 - Authentication required | http://192.168.1.100:9200/speedtest-index/_doc
2026-01-16T03:00:00Z | SUCCESS | HTTP 200 - Upload: 10.45Mbps, Res: 1080p_high | http://192.168.1.100:9200/speedtest-index/_doc
```

**Log Features:**

- Automatically rotates to keep only last 50 records
- Shows success/failure status
- Includes upload speed and recommended resolution on success
- Records HTTP response codes
- Timestamps in ISO 8601 format

**View Log:**

```bash
# View all records
cat /tmp/speedtest_elk_send.log

# View last 10 records
tail -10 /tmp/speedtest_elk_send.log

# Watch log in real-time
tail -f /tmp/speedtest_elk_send.log

# Count successful sends
grep SUCCESS /tmp/speedtest_elk_send.log | wc -l

# Count failed sends
grep FAILED /tmp/speedtest_elk_send.log | wc -l
```

### Create Kibana Dashboard for Camera Resolution Tracking

**1. Create Index Pattern:**

- Go to Kibana → Stack Management → Index Patterns
- Create pattern: `speedtest-index*`
- Select timestamp field: `timestamp`

**2. Useful Visualizations:**

- **Line Chart:** Upload speed over time
- **Gauge:** Current recommended resolution
- **Table:** Last 24 hours of tests with recommendations
- **Metric:** Average upload/download speeds

**3. Sample Kibana Query (Discover):**

```
device_name: "Teltonika_Speedtest" AND recommended_resolution: "1080p_high"
```

### Example JSON Output Format for ELK

```json
{
  "timestamp": "2026-01-16T00:17:55Z",
  "device_name": "Teltonika_Speedtest",
  "download_mbps": "4.42",
  "upload_mbps": "11.92",
  "ping_ms": "0.00",
  "recommended_resolution": "1080p_high"
}
```

**Key Fields for Dashboard:**

- `timestamp` - Time series data
- `upload_mbps` - Primary metric for camera quality
- `download_mbps` - Network health indicator
- `recommended_resolution` - Camera configuration guidance
- `ping_ms` - Network latency
- `device_name` - Device identifier

## Data to Server Integration

### Solar Controller Setup

1. Go to: Services → Data to Server → Collector Configuration
2. Add new collector:
   - **Name:** Solar_Monitor
   - **Script:** `/root/lua_script_handle_data_request_02.lua`
   - **Function:** `handle_data_request`
3. Configure sending interval (recommended: 5-15 minutes)

### Speedtest Monitor Setup

1. Go to: Services → Data to Server → Collector Configuration
2. Add new collector:
   - **Name:** Speedtest_Monitor
   - **Script:** `/root/teltonika_speedtest_monitor.lua`
   - **Function:** `handle_data_request`
3. Configure sending interval (recommended: 30-60 minutes to avoid excessive data usage)

## Data Output Format

### Solar Controller Data

```json
{
  "timestamp": "2026-01-16T00:00:00Z",
  "device_name": "Teltonika_B080",
  "PV_Voltage": "45.30V",
  "PV_Current": "8.50A",
  "PV_Power": "385.05W",
  "Battery_Temp": "25.30C",
  "SOC": "85%",
  "Generated_Today": "12.50kWh",
  "Consumed_Today": "8.30kWh"
}
```

### Speedtest Data

```json
{
  "timestamp": "2026-01-16T00:17:55Z",
  "device_name": "Teltonika_Speedtest",
  "download_mbps": "4.42",
  "upload_mbps": "11.92",
  "ping_ms": "0.00",
  "recommended_resolution": "1080p_high"
}
```

## Camera Resolution Recommendations

Based on upload speed:

| Upload Speed | Recommendation | Description                        |
| ------------ | -------------- | ---------------------------------- |
| ≥ 10 Mbps    | 1080p High     | 4-6 Mbps bitrate, can use 1440p/4K |
| 5-10 Mbps    | 1080p Medium   | 3-4 Mbps bitrate, stable Full HD   |
| 3-5 Mbps     | 720p High      | 2-3 Mbps bitrate or 1080p Low      |
| 1.5-3 Mbps   | 720p Medium    | 1.5-2 Mbps bitrate                 |
| 0.8-1.5 Mbps | 480p           | Medium bitrate                     |
| < 0.8 Mbps   | 360p or lower  | Consider upgrading connection      |

## Debugging & Troubleshooting

### Check System Logs (Teltonika)

```bash
logread -f
```

### Check Logstash Logs

```bash
docker logs -f <container_name>
```

### Test Connection to Teltonika

```bash
curl -u user:"pass" http://<IP>:<PORT>/
```

### Send Data to Elasticsearch

```bash
# Generate JSON
lua lua_script_json_format_login.lua > /tmp/test.json

# Send to Elastic
curl -u user:"pass" -XPOST "http://<IP>:<PORT>/test-lua-index/_doc" \
  -H 'Content-Type: application/json' \
  -d @/tmp/test.json
```

### Solar Script Issues

**Connection Failed:**

```bash
# Check if Modbus device is reachable
ping 192.168.198.230

# Test Modbus connection
telnet 192.168.198.230 502
```

**Script Not Running:**

```bash
# Check Lua installation
lua -v

# Test script syntax
lua -l lua_script_handle_data_request_02.lua
```

### Speedtest Script Issues

**Speedtest Not Found:**

```bash
# Check if speedtest is installed
which speedtest

# Install if needed (usually pre-installed on Teltonika)
opkg update
opkg install speedtest-cli
```

**Script Hangs:**

- Speedtest typically takes 30-60 seconds
- Script has 90-second timeout
- Check network connectivity

### View Log Files

```bash
# Solar monitoring
tail -n 50 /tmp/lua_script_status.log

# Speedtest monitoring
tail -n 50 /tmp/speedtest_monitor.log

# Clear logs
rm /tmp/lua_script_status.log
rm /tmp/speedtest_monitor.log
```

## Configuration

### Adjust Speedtest Interval

Edit `teltonika_speedtest_monitor.lua`:

```lua
local INTERVAL = 1800  -- 30 minutes (in seconds)
```

Change to:

- 600 = 10 minutes
- 3600 = 1 hour
- 7200 = 2 hours

### Change Solar Controller IP

Edit `lua_script_handle_data_request_02.lua`:

```lua
ip = "192.168.198.230"  -- Change to your device IP
port = 502
```

## Requirements

- Teltonika RUT device (tested on RUT251)
- Lua runtime (pre-installed on Teltonika)
- LuaSocket library (for solar script, pre-installed)
- Speedtest utility (for speedtest script, pre-installed)

## File Structure

```
NE2-D11/
├── lua_script_handle_data_request_02.lua    # Solar monitoring
├── lua_script_handle_data_request.lua       # Original version
├── teltonika_speedtest_monitor.lua          # Network speed monitor
├── teltonika_speedtest_monitor.sh           # Shell version (legacy)
├── main.py                                  # Python utilities
└── README.md                                # This file
```

## Version History

- **v2.0** (2026-01-16)

  - Added speedtest monitor script
  - Added CLI test modes
  - Improved error handling and logging
  - Added camera resolution recommendations

- **v1.0** (2026-01-15)
  - Initial solar monitoring script
  - Modbus TCP communication
  - Data to Server integration
