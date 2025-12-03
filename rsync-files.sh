#!/bin/bash
# =========================
# Configurable parameters
# =========================
LOCAL_FILE="/Volumes/Data/users.csv"      # Path to the local file
REMOTE_USER="root"                      # Your cloud server username
REMOTE_HOST="103.116.104.113"    # Your cloud server IP or hostname 103.116.104.113,103.116.104.114,103.116.104.115
REMOTE_PATH="datamining"                        # Destination folder (can be relative or absolute)
LOG_FILE="./rsync_transfer.log"            # Log file to track progress
MAX_RETRIES=10                               # Number of retries if transfer fails
SLEEP_BETWEEN_RETRIES=10                    # Seconds to wait before retry

# =========================
# Get remote home directory and adjust REMOTE_PATH if relative
# =========================
REMOTE_HOME=$(ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=10 -o TCPKeepAlive=yes "$REMOTE_USER@$REMOTE_HOST" 'echo $HOME')
if [ $? -ne 0 ]; then
    echo "Failed to get remote home directory. Exiting."
    exit 1
fi

if [[ "$REMOTE_PATH" != /* ]]; then
    REMOTE_PATH="$REMOTE_HOME/$(echo "$REMOTE_PATH" | sed 's|^~*/||')"  # Relative paths go under home
fi

# =========================
# Check if local file exists
# =========================
if [ ! -f "$LOCAL_FILE" ]; then
    echo "Error: Local file '$LOCAL_FILE' does not exist. Exiting."
    exit 1
fi

# =========================
# Check if remote directory exists, create if not
# =========================
echo "Checking if remote directory $REMOTE_PATH exists..."
ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=10 -o TCPKeepAlive=yes "$REMOTE_USER@$REMOTE_HOST" "
if [ ! -d \"$REMOTE_PATH\" ]; then
    echo 'Directory does not exist. Creating...'
    mkdir -p \"$REMOTE_PATH\"
else
    echo 'Directory exists.'
fi
"
if [ $? -ne 0 ]; then
    echo "Failed to verify/create remote directory. Exiting."
    exit 1
fi

# =========================
# Check disk space on remote server
# =========================
FILE_SIZE=$(stat -f%z "$LOCAL_FILE" 2>/dev/null || stat -c%s "$LOCAL_FILE" 2>/dev/null)
if [ -n "$FILE_SIZE" ]; then
    echo "Local file size: $(numfmt --to=iec-i --suffix=B $FILE_SIZE 2>/dev/null || echo "${FILE_SIZE} bytes")"
    echo "Checking remote disk space..."
    REMOTE_AVAIL=$(ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=10 -o TCPKeepAlive=yes "$REMOTE_USER@$REMOTE_HOST" "df -B1 \"$REMOTE_PATH\" 2>/dev/null | tail -1 | awk '{print \$4}'")
    if [ -n "$REMOTE_AVAIL" ] && [ "$REMOTE_AVAIL" -lt "$FILE_SIZE" ]; then
        echo "ERROR: Insufficient disk space on remote server!"
        echo "  Required: $(numfmt --to=iec-i --suffix=B $FILE_SIZE 2>/dev/null || echo "${FILE_SIZE} bytes")"
        echo "  Available: $(numfmt --to=iec-i --suffix=B $REMOTE_AVAIL 2>/dev/null || echo "${REMOTE_AVAIL} bytes")"
        exit 1
    fi
    ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=10 -o TCPKeepAlive=yes "$REMOTE_USER@$REMOTE_HOST" "df -h \"$REMOTE_PATH\" | tail -1"
    echo "Disk space check passed."
fi

# =========================
# Start rsync transfer
# =========================
echo "Starting rsync transfer of $LOCAL_FILE to $REMOTE_USER@$REMOTE_HOST:$REMOTE_PATH"
echo "Logging to $LOG_FILE"
RETRY_COUNT=0

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    # Optimized for large file transfers:
    # - More aggressive SSH keepalive (every 10 seconds, max 30 failures = 5 min)
    # - Disable compression for large files (faster, less CPU)
    # - Increase buffer sizes for better throughput
    # - Use partial-dir for better resume capability
    # - Use inplace for better handling of large files
    # - Longer timeout for large files
    # - Redirect both stdout and stderr, use tee to display and log simultaneously
    rsync -avh --progress --partial --partial-dir=.rsync-partial \
        --timeout=600 \
        --block-size=32768 \
        -e "ssh -o ServerAliveInterval=10 -o ServerAliveCountMax=30 -o Compression=no -o TCPKeepAlive=yes" \
        "$LOCAL_FILE" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_PATH" 2>&1 | tee -a "$LOG_FILE"
    EXIT_CODE=${PIPESTATUS[0]}
    
    if [ $EXIT_CODE -eq 0 ]; then
        echo "File transfer completed successfully!"
        # Verify file exists on remote server
        REMOTE_FILE="$REMOTE_PATH/$(basename "$LOCAL_FILE")"
        echo "Verifying file exists at $REMOTE_FILE..."
        ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=10 -o TCPKeepAlive=yes "$REMOTE_USER@$REMOTE_HOST" "ls -lh \"$REMOTE_FILE\" 2>/dev/null && echo 'File verified on remote server.' || echo 'WARNING: File not found at expected location!'"
        exit 0
    else
        echo "Transfer failed with exit code $EXIT_CODE. Retrying in $SLEEP_BETWEEN_RETRIES seconds..."
        RETRY_COUNT=$((RETRY_COUNT+1))
        if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
            sleep $SLEEP_BETWEEN_RETRIES
        fi
    fi
done

echo "File transfer failed after $MAX_RETRIES attempts. Check the log: $LOG_FILE"
exit 1


