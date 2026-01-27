#!/bin/sh

# Teltonika Network Speed Monitor & Camera Resolution Recommender
# This script checks upload speed and recommends appropriate camera resolution

LOG_FILE="/tmp/speedtest_monitor.log"
MAX_LOG_SIZE=200000  # 200KB max
INTERVAL=1800  # 30 minutes (in seconds) - more reasonable than 10m to avoid excessive data usage

# Log with timestamp
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') : $1" >> "$LOG_FILE"
    echo "$1"
}

# Rotate log if too large
rotate_log() {
    if [ -f "$LOG_FILE" ]; then
        SIZE=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null)
        if [ "$SIZE" -gt "$MAX_LOG_SIZE" ]; then
            tail -c 100000 "$LOG_FILE" > "$LOG_FILE.tmp"
            mv "$LOG_FILE.tmp" "$LOG_FILE"
        fi
    fi
}

# Check and install speedtest-cli
check_install_speedtest() {
    log_message "Checking for speedtest-cli..."
    
    # Check if speedtest is already installed
    if command -v speedtest-cli >/dev/null 2>&1; then
        log_message "✓ speedtest-cli is already installed"
        return 0
    fi
    
    if command -v speedtest >/dev/null 2>&1; then
        log_message "✓ speedtest is already installed"
        return 0
    fi
    
    log_message "speedtest-cli not found. Installing..."
    
    # Update package list
    opkg update
    
    # Try to install speedtest-cli (Python version)
    if opkg install speedtest-cli 2>&1 | tee -a "$LOG_FILE"; then
        log_message "✓ speedtest-cli installed successfully"
        return 0
    fi
    
    # Alternative: Try python3-speedtest-cli
    if opkg install python3-speedtest-cli 2>&1 | tee -a "$LOG_FILE"; then
        log_message "✓ python3-speedtest-cli installed successfully"
        return 0
    fi
    
    log_message "✗ ERROR: Failed to install speedtest-cli"
    log_message "  You may need to install it manually:"
    log_message "  opkg update && opkg install speedtest-cli"
    return 1
}

# Recommend camera resolution based on upload speed (in Mbps)
recommend_resolution() {
    UPLOAD_SPEED=$1
    
    echo ""
    echo "================================================"
    echo "CAMERA RESOLUTION RECOMMENDATION"
    echo "================================================"
    echo "Upload Speed: ${UPLOAD_SPEED} Mbps"
    echo ""
    
    # Use awk for floating point comparison
    if awk "BEGIN {exit !($UPLOAD_SPEED >= 10)}"; then
        echo "✓ EXCELLENT: 1080p @ High Bitrate (4-6 Mbps)"
        echo "  You can also use 1440p or 4K if camera supports it"
        RECOMMENDATION="1080p_high"
    elif awk "BEGIN {exit !($UPLOAD_SPEED >= 5)}"; then
        echo "✓ GOOD: 1080p @ Medium Bitrate (3-4 Mbps)"
        echo "  Stable full HD streaming"
        RECOMMENDATION="1080p_medium"
    elif awk "BEGIN {exit !($UPLOAD_SPEED >= 3)}"; then
        echo "⚠ FAIR: 720p @ High Bitrate (2-3 Mbps)"
        echo "  OR 1080p @ Low Bitrate"
        RECOMMENDATION="720p_high"
    elif awk "BEGIN {exit !($UPLOAD_SPEED >= 1.5)}"; then
        echo "⚠ LIMITED: 720p @ Medium Bitrate (1.5-2 Mbps)"
        echo "  Acceptable quality for most purposes"
        RECOMMENDATION="720p_medium"
    elif awk "BEGIN {exit !($UPLOAD_SPEED >= 0.8)}"; then
        echo "⚠ POOR: 480p @ Medium Bitrate (0.8-1.5 Mbps)"
        echo "  OR 720p @ Very Low Bitrate"
        RECOMMENDATION="480p"
    else
        echo "✗ VERY POOR: 360p or Lower (< 0.8 Mbps)"
        echo "  Consider upgrading network connection"
        RECOMMENDATION="360p"
    fi
    
    echo "================================================"
    echo ""
    
    # Log recommendation
    log_message "RECOMMENDATION: $RECOMMENDATION for ${UPLOAD_SPEED} Mbps upload"
}

# Run speedtest and parse results
run_speedtest() {
    log_message "Running speedtest..."
    
    # Try speedtest-cli first
    if command -v speedtest-cli >/dev/null 2>&1; then
        RESULT=$(speedtest-cli --simple 2>&1)
    elif command -v speedtest >/dev/null 2>&1; then
        RESULT=$(speedtest --simple 2>&1)
    else
        log_message "✗ ERROR: No speedtest command available"
        return 1
    fi
    
    if [ $? -ne 0 ]; then
        log_message "✗ ERROR: Speedtest failed"
        log_message "$RESULT"
        return 1
    fi
    
    # Parse results
    echo "$RESULT"
    
    # Extract upload speed (format: "Upload: XX.XX Mbit/s")
    UPLOAD=$(echo "$RESULT" | grep -i "upload" | awk '{print $2}')
    DOWNLOAD=$(echo "$RESULT" | grep -i "download" | awk '{print $2}')
    PING=$(echo "$RESULT" | grep -i "ping" | awk '{print $2}')
    
    if [ -z "$UPLOAD" ]; then
        log_message "✗ ERROR: Could not parse upload speed"
        return 1
    fi
    
    log_message "Results: Download=${DOWNLOAD}Mbps, Upload=${UPLOAD}Mbps, Ping=${PING}ms"
    
    # Recommend resolution based on upload speed
    recommend_resolution "$UPLOAD"
    
    return 0
}

# Main execution
main() {
    echo "========================================"
    echo "Teltonika Speedtest Monitor"
    echo "========================================"
    echo "Log file: $LOG_FILE"
    echo "Interval: $INTERVAL seconds ($(($INTERVAL / 60)) minutes)"
    echo ""
    
    rotate_log
    log_message "=== Speedtest Monitor Started ==="
    
    # Check/install speedtest
    if ! check_install_speedtest; then
        log_message "Cannot proceed without speedtest-cli"
        exit 1
    fi
    
    # Run once immediately
    log_message "Running initial speedtest..."
    run_speedtest
    
    # If run with --once flag, exit after first test
    if [ "$1" = "--once" ]; then
        log_message "Single run complete (--once flag)"
        exit 0
    fi
    
    # If run with --daemon flag, run continuously
    if [ "$1" = "--daemon" ]; then
        log_message "Running in daemon mode (interval: ${INTERVAL}s)"
        while true; do
            sleep "$INTERVAL"
            rotate_log
            run_speedtest
        done
    else
        echo ""
        echo "Single test complete."
        echo ""
        echo "To run continuously, use:"
        echo "  $0 --daemon &"
        echo ""
        echo "To run once and exit, use:"
        echo "  $0 --once"
    fi
}

# Run main function
main "$@"
