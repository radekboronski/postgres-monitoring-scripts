#!/bin/bash
# ============================================================================
# Load Generator - Simulates pipeline activity on test tables
# ============================================================================
# Usage: ./generate_load.sh [duration_minutes] [db_name] [db_user] [db_host] [db_port]
# Example: ./generate_load.sh 10 terrogence test_user localhost 5433
# ============================================================================

DURATION_MINUTES=${1:-10}
DB_NAME=${2:-terrogence}
DB_USER=${3:-test_user}
DB_HOST=${4:-localhost}
DB_PORT=${5:-5433}

PSQL_CONN="-h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME"

# Store all child PIDs
CHILD_PIDS=""

# Cleanup function - kills all children
cleanup() {
    echo ""
    echo "Stopping all workers..."
    for pid in $CHILD_PIDS; do
        kill $pid 2>/dev/null
        wait $pid 2>/dev/null
    done
    # Kill any remaining psql processes from this session
    pkill -P $$ 2>/dev/null
    echo "Done."
    exit 0
}

# Trap Ctrl+C and other signals
trap cleanup SIGINT SIGTERM EXIT

echo "============================================================================"
echo "Load Generator Started"
echo "============================================================================"
echo "Duration: ${DURATION_MINUTES} minutes"
echo "Database: ${DB_NAME} (host: ${DB_HOST}, port: ${DB_PORT})"
echo "============================================================================"
echo ""

# Test connection
if ! psql $PSQL_CONN -c "SELECT 1" > /dev/null 2>&1; then
    echo "ERROR: Cannot connect to database!"
    exit 1
fi

# Set search path to test schema
PSQL_CONN="$PSQL_CONN -c \"SET search_path TO test;\""

END_TIME=$(($(date +%s) + DURATION_MINUTES * 60))

# Worker functions - each runs in background

# Worker 1: Bulk INSERT entities (simulates new members discovery)
worker_insert_entities() {
    while [ $(date +%s) -lt $END_TIME ]; do
        psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -q <<EOF
SET search_path TO test;
INSERT INTO entities (identifier, name, type, app_type, scrapping_id, risk_score, status)
SELECT 
    'load_user_' || (random()*1000000)::int,
    'Load Test User ' || i,
    'member',
    '["telegram"]'::jsonb,
    'load_scrapping_' || (random()*1000000)::int || '_' || i,
    (random() * 10)::int,
    '1'
FROM generate_series(1, 50) AS i;
EOF
        sleep 0.5
    done
}

# Worker 2: Bulk INSERT items/messages
worker_insert_items() {
    while [ $(date +%s) -lt $END_TIME ]; do
        psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -q <<EOF
SET search_path TO test;
INSERT INTO items (group_id, sender_id, scrapping_id, timestamp, risk_score, status)
SELECT 
    (SELECT id FROM entities WHERE type = 'group' AND status = '1' ORDER BY random() LIMIT 1),
    (SELECT id FROM entities WHERE type = 'member' AND status = '1' ORDER BY random() LIMIT 1),
    'load_msg_' || (random()*1000000)::int || '_' || i,
    EXTRACT(EPOCH FROM NOW())::bigint,
    (random() * 10)::int,
    '1'
FROM generate_series(1, 100) AS i;
EOF
        sleep 0.3
    done
}

# Worker 3: UPDATE entities (simulates risk score updates / inheritance)
worker_update_entities() {
    while [ $(date +%s) -lt $END_TIME ]; do
        psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -q <<EOF
SET search_path TO test;
UPDATE entities 
SET risk_score = (random() * 10)::int,
    system_update_time = NOW()
WHERE id IN (
    SELECT id FROM entities 
    WHERE type = 'member' AND status = '1' 
    ORDER BY random() 
    LIMIT 100
);
EOF
        sleep 1
    done
}

# Worker 4: UPDATE items (simulates classification updates)
worker_update_items() {
    while [ $(date +%s) -lt $END_TIME ]; do
        psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -q <<EOF
SET search_path TO test;
UPDATE items 
SET risk_score = (random() * 10)::int,
    classifications = '["updated"]'::jsonb,
    system_update_time = NOW()
WHERE id IN (
    SELECT id FROM items 
    WHERE status = '1' 
    ORDER BY random() 
    LIMIT 200
);
EOF
        sleep 0.8
    done
}

# Worker 5: INSERT group_memberships (simulates member joins)
worker_insert_memberships() {
    while [ $(date +%s) -lt $END_TIME ]; do
        psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -q <<EOF
SET search_path TO test;
INSERT INTO group_memberships (group_id, member_id, membership_status, status)
SELECT 
    g.id,
    m.id,
    '1',
    '1'
FROM (SELECT id FROM entities WHERE type = 'group' AND status = '1' ORDER BY random() LIMIT 3) g
CROSS JOIN (SELECT id FROM entities WHERE type = 'member' AND status = '1' ORDER BY random() LIMIT 20) m
ON CONFLICT DO NOTHING;
EOF
        sleep 1
    done
}

# Worker 6: SELECT heavy queries (simulates AI summary reads)
worker_select_heavy() {
    while [ $(date +%s) -lt $END_TIME ]; do
        psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -q <<EOF
SET search_path TO test;
SELECT 
    e.id,
    e.name,
    COUNT(DISTINCT gm.group_id) as group_count,
    COUNT(DISTINCT i.id) as message_count
FROM entities e
LEFT JOIN group_memberships gm ON e.id = gm.member_id AND gm.status = '1'
LEFT JOIN items i ON e.id = i.sender_id AND i.status = '1'
WHERE e.type = 'member' AND e.status = '1'
GROUP BY e.id, e.name
ORDER BY message_count DESC
LIMIT 50;
EOF
        sleep 2
    done
}

# Worker 7: Competing UPDATEs on same rows (creates lock contention)
worker_lock_contention() {
    while [ $(date +%s) -lt $END_TIME ]; do
        # Get a random entity and update it from multiple "processes"
        ENTITY_ID=$(psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -t -A -c "SELECT id FROM test.entities WHERE status = '1' ORDER BY random() LIMIT 1;" 2>/dev/null | head -1 | tr -d '[:space:]')
        
        if [ -n "$ENTITY_ID" ] && [ "$ENTITY_ID" -eq "$ENTITY_ID" ] 2>/dev/null; then
            # Launch 3 competing updates
            for j in 1 2 3; do
                psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -q -c "
                    BEGIN;
                    UPDATE test.entities SET group_count = group_count + 1, system_update_time = NOW() WHERE id = $ENTITY_ID;
                    SELECT pg_sleep(0.1);
                    COMMIT;
                " 2>/dev/null &
            done
            wait
        fi
        sleep 2
    done
}

# Worker 8: Long transaction (holds locks)
worker_long_transaction() {
    while [ $(date +%s) -lt $END_TIME ]; do
        psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -q <<EOF
SET search_path TO test;
BEGIN;
UPDATE entities SET system_update_time = NOW() WHERE id IN (SELECT id FROM entities WHERE status = '1' LIMIT 10);
SELECT pg_sleep(5);
UPDATE items SET system_update_time = NOW() WHERE id IN (SELECT id FROM items WHERE status = '1' LIMIT 50);
COMMIT;
EOF
        sleep 3
    done
}

echo "Starting workers..."
echo ""

# Start all workers in background
worker_insert_entities &
PID1=$!
CHILD_PIDS="$PID1"
echo "  [PID $PID1] Worker: INSERT entities"

worker_insert_items &
PID2=$!
CHILD_PIDS="$CHILD_PIDS $PID2"
echo "  [PID $PID2] Worker: INSERT items"

worker_update_entities &
PID3=$!
CHILD_PIDS="$CHILD_PIDS $PID3"
echo "  [PID $PID3] Worker: UPDATE entities"

worker_update_items &
PID4=$!
CHILD_PIDS="$CHILD_PIDS $PID4"
echo "  [PID $PID4] Worker: UPDATE items"

worker_insert_memberships &
PID5=$!
CHILD_PIDS="$CHILD_PIDS $PID5"
echo "  [PID $PID5] Worker: INSERT memberships"

worker_select_heavy &
PID6=$!
CHILD_PIDS="$CHILD_PIDS $PID6"
echo "  [PID $PID6] Worker: SELECT heavy"

worker_lock_contention &
PID7=$!
CHILD_PIDS="$CHILD_PIDS $PID7"
echo "  [PID $PID7] Worker: Lock contention"

worker_long_transaction &
PID8=$!
CHILD_PIDS="$CHILD_PIDS $PID8"
echo "  [PID $PID8] Worker: Long transactions"

echo ""
echo "All workers started. Press Ctrl+C to stop."
echo ""

# Progress display
while [ $(date +%s) -lt $END_TIME ]; do
    REMAINING=$(( (END_TIME - $(date +%s)) / 60 ))
    ACTIVE=0
    for pid in $CHILD_PIDS; do
        if kill -0 $pid 2>/dev/null; then
            ACTIVE=$((ACTIVE + 1))
        fi
    done
    printf "\r[%s] Active workers: %d/8 | Remaining: %d min    " "$(date '+%H:%M:%S')" "$ACTIVE" "$REMAINING"
    sleep 5
done

echo ""
echo ""
echo "Time's up."
# cleanup will be called by EXIT trap
