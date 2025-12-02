#!/bin/bash
# ============================================================================
# Pipeline Monitor - Collects diagnostics during pipeline run
# ============================================================================
# Usage: ./monitor_pipeline.sh [duration_minutes] [db_name] [db_user] [db_host] [db_port] [schema]
# Example: ./monitor_pipeline.sh 60 terrogence postgres localhost 5432 public
#          ./monitor_pipeline.sh 60 terrogence postgres /tmp 5432 test
#          ./monitor_pipeline.sh 60 terrogence radek localhost 5433
# ============================================================================

DURATION_MINUTES=${1:-60}
DB_NAME=${2:-terrogence}
DB_USER=${3:-test_user}
DB_HOST=${4:-localhost}
DB_PORT=${5:-5433}
DB_SCHEMA=${6:-"test, public"}

# Intervals (in seconds)
LIGHT_INTERVAL=30      # Lightweight check every 30 sec
FULL_INTERVAL=300      # Full diagnostic every 5 min

# Build psql connection string
if [[ "$DB_HOST" == /* ]]; then
    # Socket path
    PSQL_CONN="-h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME"
else
    # TCP host
    PSQL_CONN="-h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME"
fi

# Output directory
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="pipeline_monitor_${TIMESTAMP}"
mkdir -p "$OUTPUT_DIR"

# Files
LIGHT_LOG="$OUTPUT_DIR/monitor_light.log"
FULL_LOG="$OUTPUT_DIR/monitor_full.log"
SUMMARY_LOG="$OUTPUT_DIR/summary.log"
LOCKS_LOG="$OUTPUT_DIR/locks_detected.log"

# Test connection first
echo "Testing database connection..."
if ! psql $PSQL_CONN -c "SELECT 1" > /dev/null 2>&1; then
    echo "ERROR: Cannot connect to database!"
    echo "Tried: psql $PSQL_CONN"
    echo ""
    echo "Check your connection parameters or try with socket:"
    echo "  ./monitor_pipeline.sh 10 terrogence $USER /tmp"
    echo "  ./monitor_pipeline.sh 10 terrogence $USER /var/run/postgresql"
    exit 1
fi
echo "Connection OK!"
echo ""

echo "============================================================================"
echo "Pipeline Monitor Started"
echo "============================================================================"
echo "Duration: ${DURATION_MINUTES} minutes"
echo "Database: ${DB_NAME} (host: ${DB_HOST}, port: ${DB_PORT}, user: ${DB_USER}, schema: ${DB_SCHEMA})"
echo "Output: ${OUTPUT_DIR}/"
echo "Light samples: every ${LIGHT_INTERVAL}s"
echo "Full diagnostics: every ${FULL_INTERVAL}s"
echo "============================================================================"
echo ""

# Calculate end time
END_TIME=$(($(date +%s) + DURATION_MINUTES * 60))
LAST_FULL_RUN=0
SAMPLE_COUNT=0
LOCK_EVENTS=0

# Header for logs
echo "Pipeline Monitor Log - Started $(date)" > "$LIGHT_LOG"
echo "Pipeline Monitor Log - Started $(date)" > "$FULL_LOG"
echo "" > "$LOCKS_LOG"

# Function to run light monitor
run_light_monitor() {
    echo "" >> "$LIGHT_LOG"
    echo "========== SAMPLE $SAMPLE_COUNT - $(date '+%Y-%m-%d %H:%M:%S') ==========" >> "$LIGHT_LOG"
    
    psql $PSQL_CONN -q -c "SET search_path TO $DB_SCHEMA;" -f pg_monitor_light.sql 2>&1 >> "$LIGHT_LOG"
    
    # Check for blocking - if found, log separately
    BLOCKED=$(psql $PSQL_CONN -t -c "
        SELECT COUNT(*) FROM pg_stat_activity 
        WHERE wait_event_type = 'Lock' AND cardinality(pg_blocking_pids(pid)) > 0;
    " 2>/dev/null | tr -d ' ')
    
    if [ "$BLOCKED" -gt 0 ] 2>/dev/null; then
        echo "!!! $(date '+%H:%M:%S') - BLOCKING DETECTED: $BLOCKED queries blocked !!!" | tee -a "$LOCKS_LOG"
        LOCK_EVENTS=$((LOCK_EVENTS + 1))
        
        # Capture detailed lock info
        psql $PSQL_CONN -c "
            SELECT 
                NOW() AS detected_at,
                blocked.pid AS blocked_pid,
                blocking.pid AS blocking_pid,
                NOW() - blocked.query_start AS wait_time,
                blocked.query AS blocked_query,
                blocking.query AS blocking_query
            FROM pg_stat_activity blocked
            JOIN pg_stat_activity blocking 
                ON blocking.pid = ANY(pg_blocking_pids(blocked.pid))
            WHERE blocked.wait_event_type = 'Lock';
        " >> "$LOCKS_LOG" 2>&1
    fi
    
    SAMPLE_COUNT=$((SAMPLE_COUNT + 1))
}

# Function to run full diagnostic
run_full_diagnostic() {
    echo "" >> "$FULL_LOG"
    echo "========== FULL DIAGNOSTIC - $(date '+%Y-%m-%d %H:%M:%S') ==========" >> "$FULL_LOG"
    
    psql $PSQL_CONN -c "SET search_path TO $DB_SCHEMA;" -f pg_diagnostic_queries.sql 2>&1 >> "$FULL_LOG"
}

# Main monitoring loop
echo "Monitoring started. Press Ctrl+C to stop early."
echo ""

while [ $(date +%s) -lt $END_TIME ]; do
    CURRENT_TIME=$(date +%s)
    REMAINING=$((END_TIME - CURRENT_TIME))
    REMAINING_MIN=$((REMAINING / 60))
    
    # Progress indicator
    printf "\r[%s] Samples: %d | Lock events: %d | Remaining: %d min    " \
        "$(date '+%H:%M:%S')" "$SAMPLE_COUNT" "$LOCK_EVENTS" "$REMAINING_MIN"
    
    # Run light monitor
    run_light_monitor
    
    # Run full diagnostic if interval passed
    if [ $((CURRENT_TIME - LAST_FULL_RUN)) -ge $FULL_INTERVAL ]; then
        echo ""
        echo "[$(date '+%H:%M:%S')] Running full diagnostic..."
        run_full_diagnostic
        LAST_FULL_RUN=$CURRENT_TIME
    fi
    
    # Sleep until next sample
    sleep $LIGHT_INTERVAL
done

echo ""
echo ""
echo "============================================================================"
echo "Monitoring Complete"
echo "============================================================================"

# Run final problem analysis
echo ""
echo "Running final problem analysis..."
PROBLEM_LOG="$OUTPUT_DIR/problem_analysis.log"
echo "========== PROBLEM ANALYSIS - $(date '+%Y-%m-%d %H:%M:%S') ==========" > "$PROBLEM_LOG"

if [ -f "pg_problem_analysis.sql" ]; then
    psql $PSQL_CONN -c "SET search_path TO $DB_SCHEMA;" -f pg_problem_analysis.sql 2>&1 >> "$PROBLEM_LOG"
    echo "Problem analysis complete: $PROBLEM_LOG"
else
    echo "WARNING: pg_problem_analysis.sql not found - skipping"
fi

echo ""

# Generate summary
echo "Pipeline Monitor Summary" > "$SUMMARY_LOG"
echo "========================" >> "$SUMMARY_LOG"
echo "Started: $TIMESTAMP" >> "$SUMMARY_LOG"
echo "Finished: $(date '+%Y%m%d_%H%M%S')" >> "$SUMMARY_LOG"
echo "Duration: ${DURATION_MINUTES} minutes" >> "$SUMMARY_LOG"
echo "Total samples: $SAMPLE_COUNT" >> "$SUMMARY_LOG"
echo "Lock events detected: $LOCK_EVENTS" >> "$SUMMARY_LOG"
echo "" >> "$SUMMARY_LOG"

# Extract key metrics from full log
echo "Key Findings:" >> "$SUMMARY_LOG"
echo "-------------" >> "$SUMMARY_LOG"

if [ $LOCK_EVENTS -gt 0 ]; then
    echo "WARNING: $LOCK_EVENTS lock events detected - see locks_detected.log" >> "$SUMMARY_LOG"
else
    echo "OK: No blocking locks detected" >> "$SUMMARY_LOG"
fi

# Show file sizes
echo "" >> "$SUMMARY_LOG"
echo "Output Files:" >> "$SUMMARY_LOG"
ls -lh "$OUTPUT_DIR"/ >> "$SUMMARY_LOG"

# Display summary
cat "$SUMMARY_LOG"

echo ""
echo "Detailed logs in: $OUTPUT_DIR/"
echo "  - monitor_light.log  : All samples (every ${LIGHT_INTERVAL}s)"
echo "  - monitor_full.log   : Full diagnostics (every ${FULL_INTERVAL}s)"
echo "  - locks_detected.log : Blocking events (if any)"
echo "  - summary.log        : This summary"
