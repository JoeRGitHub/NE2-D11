# Speedtest Camera Resolution - Deployment Guide

## Overview

Automatic camera resolution adjustment based on network speed tests from Teltonika router B080.

## System Flow

```
Teltonika B080 (30min speedtest)
  → Elasticsearch (speedtest-* index)
  → ElastAlert2 (change detection)
  → AWS SQS (cambot-alerts queue)
  → cambot (speedtestAlertHandler)
  → PTZ Cameras (ONVIF/SOAP API)
```

## Resolution Tiers

- **4K (3840x2160)**: Upload speed ≥ 15 Mbps
- **1080P**: Upload speed ≥ 8 Mbps
- **720P**: Upload speed < 8 Mbps

---

## Deployment Steps

### 1. ElastAlert Setup (on ELK server: ubuntu@ip-10-0-10-2)

#### 1.1 Navigate to cambot-alert directory

```bash
cd ~/cambot-alert  # Wherever your cambot-alert code is
```

#### 1.2 Create .env file (if not exists)

```bash
cp .env.example .env
```

Edit `.env` and configure AWS credentials:

```bash
# Option A: Explicit credentials
AWS_ACCESS_KEY_ID=AKIA...
AWS_SECRET_ACCESS_KEY=...

# Option B: IAM role (if running on EC2)
# Leave AWS credentials blank, ensure instance has IAM role with:
# - sqs:SendMessage permission on cambot-alerts queue
```

#### 1.3 Verify the rule file exists

```bash
ls -la rules/speedtest_resolution_change.yaml
```

You should see the ElastAlert rule file. If not, copy it from your local git repo.

#### 1.4 Deploy changes

```bash
# If using Docker Compose
docker-compose restart

# Or if CI/CD handles this, just commit and push:
git add rules/speedtest_resolution_change.yaml
git commit -m "Add speedtest resolution change alert rule"
git push
# Your CI/CD will rebuild and restart the container
```

#### 1.5 Verify rule loaded

```bash
docker logs elastalert2-router-monitor --tail 100 | grep speedtest
```

Look for: `"Loaded rules: [...'speedtest_resolution_change'...]"`

---

### 2. cambot Setup (wherever cambot runs)

#### 2.1 Files already created

- ✅ `/cambot/src/services/speedtestAlertHandler.js` - Custom handler
- ✅ `/cambot/src/services/alertService.js` - Updated to route speedtest alerts

#### 2.2 Verify SQS is enabled

Check `cambot/.env` file has:

```bash
SQS_ENABLED=true
AWS_SQS_QUEUE_URL=https://sqs.us-east-1.amazonaws.com/316348991374/cambot-alerts
AWS_REGION=us-east-1
# AWS credentials or IAM role
```

#### 2.3 Deploy cambot

```bash
cd ~/cambot_main/cambot  # Or wherever cambot is
npm install  # If any new dependencies
npm restart  # Or use your deployment process
```

#### 2.4 Verify SQS polling started

Check cambot logs:

```bash
# Look for:
# "SQS service started and polling for messages"
```

---

### 3. Google Sheets Configuration

#### 3.1 Verify Routers sheet

Open your Google Sheet and ensure **Routers** sheet has:

- Column A: Router ID (e.g., "B080")
- Column F: Organization ID (links router to cameras)

Example row:

```
B080 | 10.x.x.x | admin | password | 22 | ORG001 | false | ...
```

#### 3.2 Verify Cameras sheet

Ensure cameras follow the **naming convention** and have **Auto Resolution** enabled:

**Camera ID Naming Convention:**

- Format: `{RouterID}-{CameraNumber}`
- Example: `B080-1`, `B080-2` for cameras in kit B080
- The router ID is extracted from the camera ID prefix

**Required columns:**

- Column A: Camera ID (must start with router ID, e.g., "B080-1")
- Column B: IP Address
- Column C: Username
- Column D: Password
- Column E: RTSP Port (usually 554)
- Column F: Organization ID (for user/permission grouping)
- **Column G: Auto Resolution** (set to "Enable" to allow automatic resolution changes)

Example rows:

```
B080-1 | 192.168.198.228 | admin | pass | 554 | ORG001 | Enable
B080-2 | 192.168.198.229 | admin | pass | 554 | ORG001 | Enable
B080-3 | 192.168.198.230 | admin | pass | 554 | ORG001 |        (Auto disabled)
B081-1 | 192.168.199.100 | admin | pass | 554 | ORG001 | Enable  (Different kit)
```

**Important**:

- Cameras with IDs starting with **"B080"** will be affected by B080's speedtest
- Only cameras with **"Enable" in column G** will have their resolution automatically adjusted
- Each router independently manages cameras with its prefix
- Cameras may be offline/unconfigured - system handles gracefully

#### 3.3 (Optional) Add Alert Routing for notifications

In **Alert Routing** sheet, add:

| Alert Type                  | Alert Sender | Recipients              | Action | Action Target |
| --------------------------- | ------------ | ----------------------- | ------ | ------------- |
| speedtest_resolution_change | \*           | +1234567890,+0987654321 |        |               |

This controls who receives WhatsApp notifications about resolution changes.

**Note**: The speedtest handler automatically processes cameras whose Camera ID starts with the router ID (e.g., B080-1, B080-2), so the "Action" and "Action Target" columns are not used for this alert type.

---

### 4. Teltonika Router Setup (B080)

#### 4.1 Upload Lua script

```bash
# SSH into B080
ssh root@<B080_IP>

# Upload teltonika_speedtest_monitor_clean.lua to /etc/config/
scp teltonika_speedtest_monitor_clean.lua root@<B080_IP>:/etc/config/
```

#### 4.2 Configure "Data to Server"

In Teltonika WebUI:

1. Go to **Services → Data to Server**
2. Enable the service
3. Configuration:
   - **Server**: `http://23.22.239.108:9200/speedtest-<device_name>/_doc`
   - **Method**: POST
   - **Headers**:
     ```
     Content-Type: application/json
     Authorization: Basic ZWxhc3RpYzplb3hHLVlDZDkqRWk5N1BoNnZfOQ==
     ```
     (This is base64 of `elastic:eoxG-YCd9*Ei97Ph6v_9`)
   - **Lua Script**: Select `teltonika_speedtest_monitor_clean.lua`
   - **Interval**: 1800 seconds (30 minutes)

#### 4.3 Test manually

```bash
# SSH to B080
ssh root@<B080_IP>

# Run script once
cd /etc/config
lua teltonika_speedtest_monitor_clean.lua --once

# Check output for recommended resolution
# Then verify data appears in Elasticsearch
```

---

## Testing End-to-End

### Test 1: Elasticsearch Receives Data

```bash
# Query Elasticsearch
curl -u elastic:eoxG-YCd9*Ei97Ph6v_9 \
  "http://23.22.239.108:9200/speedtest-*/_search?pretty" \
  -H 'Content-Type: application/json' \
  -d '{"size": 1, "sort": [{"@timestamp": "desc"}]}'

# Check for:
# - device_name: "B080"
# - recommended_resolution: "3840x2160" or "1080P" or "720P"
# - upload_mbps, download_mbps, ping_ms values
```

### Test 2: ElastAlert Detects Change

```bash
# Watch ElastAlert logs
docker logs -f elastalert2-router-monitor

# Trigger a speedtest with different network conditions
# ElastAlert should detect resolution recommendation change
# Look for: "Alert sent to SQS" or similar
```

### Test 3: cambot Receives Alert

```bash
# Watch cambot logs
# Look for:
# "Processing speedtest resolution change alert"
# "Found router: B080, organizationId: ORG001"
# "Found cameras for organization: 2 cameras"
# "Applying resolution change to camera CAM001"
# "Resolution changed successfully"
```

### Test 4: Cameras Updated

```bash
# Check camera actually changed resolution
# Method 1: Log into camera WebUI, check video settings
# Method 2: Check cambot logs for "Resolution changed successfully"
# Method 3: WhatsApp notification received by users
```

---

## Troubleshooting

### No data in Elasticsearch

- Check Teltonika "Data to Server" is enabled
- Verify Lua script runs: SSH to B080, run manually
- Check Elasticsearch is accessible from B080 network
- Verify Authorization header is correct

### ElastAlert not triggering

- Check rule loaded: `docker logs elastalert2-router-monitor | grep speedtest`
- Verify resolution actually changed (same resolution won't trigger)
- Check 30-minute `realert` window (won't alert twice in 30 min)
- Review ElastAlert logs for errors

### SQS messages not received

- Verify SQS enabled in cambot `.env`
- Check AWS credentials/IAM role permissions
- Confirm queue URL is correct: `cambot-alerts` in `us-east-1`
- Check cambot logs: "SQS service started and polling"

### Cameras not updating

- **Check Camera ID naming**: Verify camera ID starts with router ID (e.g., "B080-1" for router B080)
- **Check Auto Resolution column**: Verify camera has "Enable" in column G of Cameras sheet
- Check camera is accessible (ping, ONVIF port 80)
- Review cambot logs for specific camera errors
- Ensure resolution value matches supported formats: `3840x2160`, `1080P`, `720P`

### Duplicate alerts

- ElastAlert has 30-min `realert` to prevent spam
- speedtestAlertHandler tracks last resolution per router (30-min minimum)
- If same resolution detected twice within 30 min, silently skipped

---

## Architecture Notes

### Why Camera ID prefix instead of separate Router ID column?

- **Inherent in naming convention**: Camera ID "B080-1" naturally encodes router ownership
- **No extra column needed**: Router ID extracted by parsing camera ID prefix
- **Matches physical reality**: Kit B080 contains cameras B080-1, B080-2, etc.
- **Simple and clear**: Easy to understand which cameras belong to which kit
- **Example**:
  - B080-1, B080-2 → Managed by router B080
  - B081-1, B081-2 → Managed by router B081
  - System parses "B080" from "B080-1" using `cameraId.split('-')[0]`

### Why organizationId still exists (Column F)?

- Used for **user permissions and notifications** (not for speedtest routing)
- Groups cameras/routers for administrative purposes
- Determines who receives WhatsApp notifications
- Separate concern from speedtest-based resolution changes

### Why custom handler instead of Alert Routing sheet?

- Speedtest alerts target routers (B080), not cameras
- Need to apply resolution to **multiple cameras** per alert
- Standard alert flow is 1 alert → 1 action → 1 camera
- Custom handler allows 1 alert → N cameras with proper error handling

### Router-to-Camera mapping (Camera ID prefix)

- **Direct assignment**: Camera ID contains router prefix (e.g., "B080-1")
- **Independent operation**: Each router's speedtest only affects its own cameras
- **Example**: Router B080 at 10 Mbps → only B080-\* cameras drop to 1080P
- **Flexibility**: Rename camera ID to reassign to different router
- **No cascading**: B080's speed doesn't affect B081's cameras, even in same organization
- **Handles offline cameras**: System gracefully skips cameras that are unconfigured/offline

### Auto Resolution filtering (Column G)

- **Opt-in control**: Only cameras with "Enable" in the Auto Resolution column are automatically adjusted
- **Safety**: Prevents accidental resolution changes on critical/special cameras
- **Flexibility**: Easy to enable/disable per camera without code changes
- **Audit trail**: Clear in Google Sheets which cameras participate in auto-adjustment
- **Example use cases**:
  - Disable for cameras with custom resolution requirements
  - Disable for cameras under testing or maintenance
  - Enable only for standard surveillance cameras

### Deduplication strategy

1. **ElastAlert `realert: 30 minutes`** - Prevents alert spam if resolution oscillates
2. **speedtestAlertHandler cache** - Tracks last resolution per router, ignores duplicates within 30 min
3. **Alert Routing matching** - Only routes to intended recipients

---

## Monitoring

### Key Metrics to Track

- Speedtest frequency: Should be every 30 minutes
- Resolution change frequency: Depends on network stability
- Camera update success rate: Should be >95%
- Alert processing time: Should be <2 minutes end-to-end

### Log Locations

- **Teltonika**: `/var/log/messages` (system log)
- **Elasticsearch**: `docker logs elasticsearch`
- **ElastAlert**: `docker logs elastalert2-router-monitor`
- **cambot**: Wherever cambot logs are configured
- **Cameras**: WebUI logs or ONVIF device management

---

## Rollback Plan

### If issues occur:

**Disable ElastAlert rule:**

```bash
# Rename rule file to disable it
cd ~/cambot-alert/rules
mv speedtest_resolution_change.yaml speedtest_resolution_change.yaml.disabled
docker-compose restart
```

**Disable Teltonika speedtest:**

```
# In Teltonika WebUI
Services → Data to Server → Disable
```

**Disable cambot SQS processing:**

```bash
# In cambot/.env
SQS_ENABLED=false
# Restart cambot
```

The system is designed to fail gracefully:

- If ElastAlert is down, speedtests still run (just no alerts)
- If cambot is down, alerts queue in SQS (processed when cambot restarts)
- If camera updates fail, other cameras still process
- All errors logged with full context

---

## Next Steps

1. ✅ Deploy ElastAlert rule
2. ✅ Deploy cambot updates
3. ✅ Configure Google Sheets (verify organizationId)
4. ⏳ Upload Lua script to B080
5. ⏳ Configure "Data to Server" on B080
6. ⏳ End-to-end testing
7. ⏳ Monitor for 24-48 hours
8. ⏳ Document actual behavior and adjust thresholds if needed

## Questions?

If you encounter issues, check:

1. This deployment guide troubleshooting section
2. `SPEEDTEST_CAMERA_FLOW.md` for system architecture
3. cambot/ElastAlert logs for specific errors
