-- ============================================================================
-- LIGHTWEIGHT MONITOR - Run every 30-60 seconds during pipeline
-- ============================================================================
-- Captures: connections, locks, blocking, wait events, table activity
-- Fast execution (~100-200ms)
-- ============================================================================

\pset pager off
\timing off

-- Set schema search path (change 'test' to your schema if different)
SET search_path TO test, public;

-- Timestamp for this sample
SELECT NOW() AS sample_time, 'SAMPLE START' AS marker;

-- 1. Connection summary (total, by state, limits)
SELECT 
    COUNT(*) AS total_connections,
    COUNT(*) FILTER (WHERE state = 'active') AS active,
    COUNT(*) FILTER (WHERE state = 'idle') AS idle,
    COUNT(*) FILTER (WHERE state = 'idle in transaction') AS idle_in_tx,
    COUNT(*) FILTER (WHERE wait_event_type = 'Lock') AS waiting_on_lock,
    current_setting('max_connections')::int AS max_conn,
    ROUND(100.0 * COUNT(*) / current_setting('max_connections')::int, 1) AS usage_pct
FROM pg_stat_activity
WHERE pid != pg_backend_pid();

-- 2. Active queries count by state (detail)
SELECT 
    state,
    COUNT(*) AS cnt,
    COUNT(*) FILTER (WHERE wait_event_type = 'Lock') AS waiting_on_lock
FROM pg_stat_activity
WHERE pid != pg_backend_pid()
GROUP BY state;

-- 3. Activity on pipeline tables RIGHT NOW (queries hitting each table)
SELECT 
    COALESCE(relname, 'OTHER') AS table_name,
    COUNT(*) AS active_queries,
    COUNT(*) FILTER (WHERE query ~* 'INSERT') AS inserts,
    COUNT(*) FILTER (WHERE query ~* 'UPDATE') AS updates,
    COUNT(*) FILTER (WHERE query ~* 'DELETE') AS deletes,
    COUNT(*) FILTER (WHERE query ~* 'SELECT') AS selects
FROM pg_stat_activity a
LEFT JOIN pg_locks l ON a.pid = l.pid AND l.granted
LEFT JOIN pg_class c ON l.relation = c.oid
WHERE a.state = 'active'
  AND a.pid != pg_backend_pid()
  AND (c.relname IN ('entities', 'group_memberships', 'items', 
                     'entity_images', 'message_application_data',
                     'personal_details', 'phone_appdata', 'entity_relations',
                     'group_application_data', 'item_reactions') 
       OR c.relname IS NULL)
GROUP BY relname
ORDER BY active_queries DESC;

-- 4. Table operations since last stats reset (cumulative - shows trends)
SELECT 
    relname AS table_name,
    n_tup_ins AS inserts,
    n_tup_upd AS updates,
    n_tup_del AS deletes,
    n_live_tup AS live_rows,
    n_dead_tup AS dead_rows
FROM pg_stat_user_tables
WHERE relname IN ('entities', 'group_memberships', 'items', 
                  'entity_images', 'message_application_data',
                  'personal_details', 'phone_appdata')
ORDER BY n_tup_ins + n_tup_upd DESC;

-- 5. Blocked queries (CRITICAL - any row here = problem)
SELECT 
    blocked.pid AS blocked_pid,
    blocking.pid AS blocking_pid,
    NOW() - blocked.query_start AS wait_duration,
    LEFT(blocked.query, 60) AS blocked_query,
    blocked.wait_event
FROM pg_stat_activity blocked
JOIN pg_stat_activity blocking 
    ON blocking.pid = ANY(pg_blocking_pids(blocked.pid))
WHERE blocked.wait_event_type = 'Lock';

-- 6. Long-running queries (>10 seconds)
SELECT 
    pid,
    NOW() - query_start AS duration,
    state,
    wait_event_type,
    wait_event,
    LEFT(query, 80) AS query
FROM pg_stat_activity
WHERE state != 'idle'
  AND pid != pg_backend_pid()
  AND NOW() - query_start > interval '10 seconds'
ORDER BY query_start;

-- 7. Lock conflicts by table (if any)
SELECT 
    l.relation::regclass AS table_name,
    l.mode,
    COUNT(*) AS lock_count,
    COUNT(*) FILTER (WHERE NOT l.granted) AS waiting
FROM pg_locks l
WHERE l.relation IS NOT NULL
GROUP BY l.relation::regclass, l.mode
HAVING COUNT(*) FILTER (WHERE NOT l.granted) > 0;

-- 8. Wait events snapshot
SELECT 
    wait_event_type,
    wait_event,
    COUNT(*) AS cnt
FROM pg_stat_activity
WHERE wait_event IS NOT NULL
  AND state = 'active'
GROUP BY wait_event_type, wait_event
ORDER BY cnt DESC
LIMIT 10;

SELECT NOW() AS sample_time, 'SAMPLE END' AS marker;
