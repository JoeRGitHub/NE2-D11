# Teltonika Speedtest to Camera Resolution - Complete System Flow

## Overview

Full flow end-to-end:

1. **Teltonika (B080)** runs the Lua script every 30 min → measures upload speed → calculates estimated capacity → decides recommended resolution → sends JSON to Elasticsearch (`speedtest-*` index)

2. **ElastAlert** (running on your ELK server) checks every minute → detects when `recommended_resolution` changed for `B080` → sends alert to AWS SQS

3. **cambot** polls SQS → receives the alert → reads the Cameras sheet from Google Sheets → filters cameras where:
   - Camera ID starts with `B080` (same router)
   - Column G = `Enable`

4. For each matching camera → calls `changeResolutionOperation` with the new resolution

So the only two things you need to do to activate it for a camera:

- Put `Enable` in column G of that camera's row in the Cameras sheet
- Deploy the Lua script to the B080 Teltonika router

Automated system that monitors network upload speed on Teltonika router and dynamically adjusts PTZ camera resolution based on available bandwidth.

**Components:**

- Teltonika RUT251 router (B080) - Network speed monitoring
- Elasticsearch - Data storage and indexing
- ElastAlert - Change detection and alerting
- AWS SQS - Message queue
- cambot - WhatsApp bot with camera control

---

## Stage 1: Teltonika Speedtest (Every 30 minutes)

**Location**: Teltonika RUT251 router (B080)  
**Script**: `teltonika_speedtest_monitor_clean.lua`  
**Trigger**: Teltonika "Data to Server" service

### Process

1. **Speedtest Execution**
   - Runs every 30 minutes (1800 seconds)
   - Measures: Download, Upload, Ping
   - Uses `speedtest-cli` or built-in `speedtest` command

2. **Resolution Calculation**

   ```lua
   if upload_speed >= 15 then
       return "3840x2160"  -- 4K
   elseif upload_speed >= 8 then
       return "1080P"      -- Full HD
   else
       return "720P"       -- HD
   end
   ```

3. **Speed Thresholds**
   - **≥ 15 Mbps** → 4K (3840x2160)
   - **≥ 8 Mbps** → 1080P
   - **< 8 Mbps** → 720P

4. **JSON Payload Created**

   ```json
   {
     "timestamp": "2026-03-18T10:30:00Z",
     "device_name": "B080",
     "download_mbps": 45.2,
     "upload_mbps": 12.5,
     "ping_ms": 15.3,
     "recommended_resolution": "1080P"
   }
   ```

5. **Sends to Elasticsearch**
   - Target: Configured ELK endpoint
   - Method: HTTP POST
   - Logs result to `/tmp/speedtest_elk_send.log`

---

## Stage 2: Elasticsearch Storage

**Location**: Elasticsearch server (23.22.239.108:9200)  
**Index Pattern**: `speedtest-*`

### Storage

**Document Structure:**

```json
{
  "@timestamp": "2026-03-18T10:30:00Z",
  "device_name": "B080",
  "download_mbps": 45.2,
  "upload_mbps": 12.5,
  "ping_ms": 15.3,
  "recommended_resolution": "1080P"
}
```

**Indexed Fields:**

- `@timestamp` - Time of measurement
- `device_name` - Router identifier (B080)
- `upload_mbps` - Upload speed measurement
- `recommended_resolution` - Calculated resolution
- All fields searchable and aggregatable

---

## Stage 3: ElastAlert Detection

**Location**: cambot-alert container  
**Service**: ElastAlert2 monitoring Elasticsearch

### Alert Rule Configuration

**Rule Type**: Change detection

```yaml
name: speedtest_resolution_change
type: change
index: speedtest-*
compare_key: recommended_resolution
query_key: device_name
ignore_null: true
timeframe:
  minutes: 60
realert:
  minutes: 30
```

### Trigger Conditions

**Example Scenario:**

- **Previous reading** (10:00): `720P` @ 6.5 Mbps
- **Current reading** (10:30): `1080P` @ 12.5 Mbps
- **Result**: Alert triggered! Resolution change detected

### SQS Message Sent

```json
{
  "alert_type": "speedtest_resolution_change",
  "device_name": "B080",
  "previous_resolution": "720P",
  "new_resolution": "1080P",
  "upload_mbps": 12.5,
  "download_mbps": 45.2,
  "ping_ms": 15.3,
  "timestamp": "2026-03-18T10:30:00Z"
}
```

**Target**: AWS SQS Queue `cambot-alerts`

---

## Stage 4: cambot Processing

**Location**: cambot WhatsApp bot server  
**Component**: SQS message handler

### Processing Steps

1. **Receives SQS Message**
   - Polls queue every 30-60 seconds
   - Retrieves speedtest alert

2. **Resolution Mapping**

   ```javascript
   const resolutionMap = {
     "3840x2160": { api: "3840x2160", display: "4K" },
     "1080P": { api: "1080P", display: "1080P" },
     "720P": { api: "720P", display: "720P" },
   };
   ```

3. **Camera Lookup & Filtering**
   - Queries Google Sheets for cameras whose ID starts with "B080" (parsed from Camera ID)
   - **Filters for Auto Resolution enabled**: Only cameras with "Enable" in column G
   - Example: B080-1, B080-2 - both with Auto Resolution enabled

4. **Executes changeResolutionOperation**
   - For each camera:
     - ✓ Validates camera is online (ping + API check)
     - ✓ Backs up current configuration
     - ✓ Applies new resolution via SOAP
     - ✓ Verifies change succeeded
     - ✓ Logs operation result

5. **WhatsApp Notification** (Optional)

   ```
   📹 Camera Resolution Updated

   Device: B080
   Upload Speed: 12.5 Mbps

   Cameras updated to 1080P:
   ✓ CAM001 - Front Gate
   ✓ CAM002 - Parking Lot

   Previous: 720P
   Reason: Network speed improved
   Time: 10:30 AM
   ```

---

## Stage 5: Camera Adjustment

**Location**: PTZ Camera (Network IP camera)  
**Protocol**: ONVIF/SOAP API

### Camera Update Process

1. **Receives SOAP Request** from cambot

   ```xml
   <SetConfiguration>
     <VideoEncoderConfiguration>
       <Resolution>
         <Width>1920</Width>
         <Height>1080</Height>
       </Resolution>
       <RateControl>
         <BitrateLimit>4000</BitrateLimit>
       </RateControl>
     </VideoEncoderConfiguration>
   </SetConfiguration>
   ```

2. **Camera Applies Settings**
   - Changes stream resolution (1920x1080)
   - Adjusts bitrate accordingly
   - Brief stream interruption (2-3 seconds)
   - Saves configuration to persistent memory

3. **Responds to cambot**
   - Success/failure status
   - New configuration details

4. **cambot Verifies**
   - Reads back camera configuration
   - Confirms resolution matches request
   - Logs final result

---

## Complete Timeline Example

### Scenario: Network Speed Improves Throughout Day

```
10:00 AM - Network Congestion
├─ Speedtest: 6.5 Mbps upload
├─ Recommendation: 720P
├─ Sent to ELK
├─ Camera currently at 720P
└─ No change needed ✓

10:30 AM - Network Improves
├─ Speedtest: 12.5 Mbps upload
├─ Recommendation: 1080P → CHANGE!
├─ Sent to ELK
├─ ElastAlert detects: 720P → 1080P
├─ Alert sent to SQS
├─ cambot processes alert
├─ Changes 2 cameras to 1080P
└─ WhatsApp notification sent ✓

11:00 AM - Network Stable
├─ Speedtest: 11.8 Mbps upload
├─ Recommendation: 1080P
├─ Sent to ELK
├─ ElastAlert: No change detected
└─ Camera stays at 1080P ✓

11:30 AM - Network Excellent
├─ Speedtest: 18.5 Mbps upload
├─ Recommendation: 4K → CHANGE!
├─ Sent to ELK
├─ ElastAlert detects: 1080P → 4K
├─ Alert sent to SQS
├─ cambot processes alert
├─ Changes 2 cameras to 4K
└─ WhatsApp notification sent ✓

12:00 PM - Network Excellent
├─ Speedtest: 20.2 Mbps upload
├─ Recommendation: 4K
├─ Sent to ELK
├─ ElastAlert: No change detected
└─ Camera stays at 4K ✓
```

---

## Implementation Checklist

### ✅ Already Implemented

- [x] Teltonika speedtest Lua script
- [x] Elasticsearch server configured
- [x] Camera control via changeResolutionOperation
- [x] WhatsApp notification system
- [x] Google Sheets integration

### ❌ To Be Implemented

- [ ] Update Lua script with new thresholds (15/8 Mbps)
- [ ] Create ElastAlert rule for speedtest monitoring
- [ ] Add speedtest SQS handler to cambot
- [ ] Link device B080 to cameras in Google Sheets
- [ ] Configure camera-to-device mapping
- [ ] Test end-to-end flow

---

## Configuration Requirements

### Teltonika Configuration

**File**: `teltonika_speedtest_monitor_clean.lua`

```lua
local DEVICE_NAME = "B080"
local INTERVAL = 1800  -- 30 minutes

-- Configure in Teltonika "Data to Server":
-- URL: http://your-elk-ip:9200/speedtest-*/_doc
-- Username: elastic
-- Password: your-password
```

### ElastAlert Configuration

**File**: `rules/speedtest_resolution_change.yaml`

```yaml
name: speedtest_resolution_change
type: change
index: speedtest-*
compare_key: recommended_resolution
query_key: device_name

alert:
  - sqs_alerter:
      queue_url: https://sqs.us-east-1.amazonaws.com/316348991374/cambot-alerts
```

### Google Sheets Configuration

**Sheets Required:**

1. **Routers Sheet**
   | Router ID | IP | Username | Password | SSH Port | Org ID | Blocked | ... |
   |-----------|---------|----------|----------|----------|--------|---------|-----|
   | B080 | 10.x.x.x | admin | pass | 22 | ORG001 | false | ... |

2. **Cameras Sheet**
   | Camera ID | IP | Username | Password | Port | Org ID | Auto Resolution |
   |-----------|---------------|----------|----------|------|--------|-----------------|
   | CAM001 | 192.168.1.101 | admin | pass | 554 | ORG001 | Enable |
   | CAM002 | 192.168.1.102 | admin | pass | 554 | ORG001 | Enable |
   | CAM003 | 192.168.1.103 | admin | pass | 554 | ORG001 | | (disabled)

**Key Configuration:**

- Router B080 and Cameras must have same **Org ID** (column F)
- Only cameras with **"Enable"** in Auto Resolution (column G) will be automatically adjusted
- Provides camera-level opt-in control for automatic resolution changes

---

## Troubleshooting

### Speedtest Not Running

- Check Teltonika "Data to Server" configuration
- Verify `speedtest` or `speedtest-cli` installed
- Check `/tmp/speedtest_monitor.log` for errors

### No Alerts Triggered

- Verify ElastAlert container is running
- Check Elasticsearch connection
- Review `/var/log/elastalert/elastalert.log`

### Camera Not Updating

- **Check Camera ID naming**: Verify camera ID starts with router ID (e.g., "B080-1" for router B080)
- **Check Auto Resolution column**: Verify camera has "Enable" in column G of Cameras sheet
- Verify camera is online (ping test)
- Check SOAP API accessibility
- Review cambot logs for SOAP errors
- Confirm camera supports target resolution

### Resolution Not Changing

- Check if resolution actually changed in ELK
- Verify threshold values (15/8 Mbps)
- Confirm ElastAlert `realert` time hasn't blocked it

---

## Performance Considerations

- **Speedtest Interval**: 30 minutes balances accuracy vs network load
- **ElastAlert Realert**: 30 minutes prevents excessive camera switching
- **Camera Updates**: Limited to actual resolution changes (no redundant updates)
- **Rollback**: Automatic if camera update fails (using backup configuration)

---

## Security Notes

- Elasticsearch credentials stored securely in Teltonika
- AWS SQS accessed via IAM roles (no hardcoded credentials)
- Camera SOAP credentials stored in Google Sheets (encrypted)
- WhatsApp session isolated in Docker volume

---

## Maintenance

### Regular Tasks

- Monitor `/tmp/speedtest_elk_send.log` for failures
- Review ElastAlert logs weekly
- Verify camera configurations monthly
- Update speed thresholds based on network patterns

### Log Files

- **Teltonika**: `/tmp/speedtest_monitor.log`
- **ELK Send**: `/tmp/speedtest_elk_send.log`
- **ElastAlert**: `/var/log/elastalert/`
- **cambot**: Docker logs via `docker logs cambot`

---

## Future Enhancements

- [ ] Add download speed monitoring
- [ ] Implement bitrate fine-tuning (not just resolution)
- [ ] Support multiple routers (B081, B082, etc.)
- [ ] Add manual override via WhatsApp command
- [ ] Create dashboard in Kibana for speed trends
- [ ] Add camera health monitoring integration

---

**Last Updated**: March 18, 2026  
**Version**: 1.0  
**Author**: System Integration Documentation
