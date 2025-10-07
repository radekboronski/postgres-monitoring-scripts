\set ECHO queries

\echo '============================================================================'
\echo 'PART 1: PREPARATION - ENABLING EXTENSIONS'
\echo '============================================================================'
\echo ''

\echo '----------------------------------------------------------------------------'
\echo '1.1. Required extensions (run as superuser or cloud_sql_superuser)'
\echo '----------------------------------------------------------------------------'

CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS pgstattuple;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '1.2. Check installed extensions'
\echo '----------------------------------------------------------------------------'

SELECT 
    extname AS extension_name,
    extversion AS version,
    nspname AS schema
FROM pg_extension e
JOIN pg_namespace n ON e.extnamespace = n.oid
ORDER BY extname;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '1.3. Reset statistics (optional, before starting tests)'
\echo '----------------------------------------------------------------------------'
/* Uncomment to reset statistics:
SELECT pg_stat_statements_reset();
SELECT pg_stat_reset();
*/

\echo ''
\echo '============================================================================'
\echo 'PART 2: SQL QUERY OPTIMIZATION - ANALYSIS AND OPTIMIZATION'
\echo '============================================================================'
\echo ''

\echo '----------------------------------------------------------------------------'
\echo '2.1. TOP 20 slowest queries (by average execution time)'
\echo '----------------------------------------------------------------------------'

SELECT 
    queryid,
    LEFT(query, 100) AS query_preview,
    calls,
    ROUND(total_exec_time::numeric, 2) AS total_time_ms,
    ROUND(mean_exec_time::numeric, 2) AS avg_time_ms,
    ROUND(min_exec_time::numeric, 2) AS min_time_ms,
    ROUND(max_exec_time::numeric, 2) AS max_time_ms,
    ROUND(stddev_exec_time::numeric, 2) AS stddev_time_ms,
    rows,
    ROUND((100.0 * shared_blks_hit / NULLIF(shared_blks_hit + shared_blks_read, 0))::numeric, 2) AS cache_hit_ratio,
    shared_blks_read,
    shared_blks_hit,
    shared_blks_dirtied,
    shared_blks_written,
    temp_blks_read,
    temp_blks_written
FROM pg_stat_statements
WHERE query NOT LIKE '%pg_stat_statements%'
    AND query NOT LIKE 'DEALLOCATE%'
ORDER BY mean_exec_time DESC
LIMIT 20;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '2.2. Queries with highest total execution time (cumulative impact)'
\echo '----------------------------------------------------------------------------'

SELECT 
    queryid,
    LEFT(query, 100) AS query_preview,
    calls,
    ROUND(total_exec_time::numeric, 2) AS total_time_ms,
    ROUND((total_exec_time / 1000 / 60)::numeric, 2) AS total_time_minutes,
    ROUND(mean_exec_time::numeric, 2) AS avg_time_ms,
    ROUND((100.0 * total_exec_time / SUM(total_exec_time) OVER ())::numeric, 2) AS pct_total_time,
    ROUND((100.0 * calls / SUM(calls) OVER ())::numeric, 2) AS pct_total_calls
FROM pg_stat_statements
WHERE query NOT LIKE '%pg_stat_statements%'
ORDER BY total_exec_time DESC
LIMIT 20;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '2.3. Queries with worst cache hit ratio'
\echo '----------------------------------------------------------------------------'

SELECT 
    queryid,
    LEFT(query, 100) AS query_preview,
    calls,
    shared_blks_hit,
    shared_blks_read,
    ROUND((100.0 * shared_blks_hit / NULLIF(shared_blks_hit + shared_blks_read, 0))::numeric, 2) AS cache_hit_ratio,
    ROUND(mean_exec_time::numeric, 2) AS avg_time_ms
FROM pg_stat_statements
WHERE (shared_blks_hit + shared_blks_read) > 0
    AND query NOT LIKE '%pg_stat_statements%'
ORDER BY (shared_blks_hit::float / NULLIF(shared_blks_hit + shared_blks_read, 0)) ASC
LIMIT 20;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '2.4. Queries using temp files (high I/O)'
\echo '----------------------------------------------------------------------------'

SELECT 
    queryid,
    LEFT(query, 100) AS query_preview,
    calls,
    temp_blks_read,
    temp_blks_written,
    ROUND((temp_blks_written * 8192 / 1024.0 / 1024.0)::numeric, 2) AS temp_mb_written,
    ROUND(mean_exec_time::numeric, 2) AS avg_time_ms,
    ROUND((mean_exec_time * calls / 1000)::numeric, 2) AS total_time_sec
FROM pg_stat_statements
WHERE temp_blks_written > 0
ORDER BY temp_blks_written DESC
LIMIT 20;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '2.5. Queries with high execution time variance (unstable)'
\echo '----------------------------------------------------------------------------'

SELECT 
    queryid,
    LEFT(query, 100) AS query_preview,
    calls,
    ROUND(mean_exec_time::numeric, 2) AS avg_time_ms,
    ROUND(stddev_exec_time::numeric, 2) AS stddev_ms,
    ROUND((stddev_exec_time / NULLIF(mean_exec_time, 0))::numeric, 2) AS coefficient_of_variation,
    ROUND(min_exec_time::numeric, 2) AS min_time_ms,
    ROUND(max_exec_time::numeric, 2) AS max_time_ms
FROM pg_stat_statements
WHERE calls > 10
    AND mean_exec_time > 0
    AND query NOT LIKE '%pg_stat_statements%'
ORDER BY (stddev_exec_time / NULLIF(mean_exec_time, 0)) DESC
LIMIT 20;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '2.6. Sequential scans vs Index scans ratio'
\echo '----------------------------------------------------------------------------'

SELECT 
    schemaname,
    relname AS relname,
    seq_scan,
    seq_tup_read,
    idx_scan,
    COALESCE(idx_tup_fetch, 0) AS idx_tup_fetch,
    CASE 
        WHEN seq_scan = 0 THEN 0
        ELSE ROUND((seq_tup_read::numeric / seq_scan), 2)
    END AS avg_seq_tup_per_scan,
    ROUND((100.0 * idx_scan / NULLIF(seq_scan + idx_scan, 0))::numeric, 2) AS index_usage_pct,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||relname)) AS total_size
FROM pg_stat_user_tables
WHERE seq_scan > 0 OR idx_scan > 0
ORDER BY seq_scan DESC, seq_tup_read DESC
LIMIT 30;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '2.7. Full query text for specific queryid'
\echo 'Use queryid from previous queries'
\echo '----------------------------------------------------------------------------'
/* Example: SELECT query FROM pg_stat_statements WHERE queryid = 'YOUR_QUERYID_HERE'; */

\echo ''
\echo '============================================================================'
\echo 'PART 3: SLOW QUERIES - REAL-TIME MONITORING'
\echo '============================================================================'
\echo ''

\echo '----------------------------------------------------------------------------'
\echo '3.1. Configure slow query logging (execute as admin)'
\echo '----------------------------------------------------------------------------'
/*
ALTER SYSTEM SET log_min_duration_statement = 1000;
ALTER SYSTEM SET log_line_prefix = '%t [%p]: [%l-1] user=%u,db=%d,app=%a,client=%h ';
ALTER SYSTEM SET log_checkpoints = on;
ALTER SYSTEM SET log_connections = on;
ALTER SYSTEM SET log_disconnections = on;
ALTER SYSTEM SET log_lock_waits = on;
ALTER SYSTEM SET log_temp_files = 0;
SELECT pg_reload_conf();
*/

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '3.2. Current active queries (real-time monitoring)'
\echo '----------------------------------------------------------------------------'

SELECT 
    pid,
    usename,
    application_name,
    client_addr,
    backend_start,
    xact_start,
    query_start,
    state_change,
    state,
    wait_event_type,
    wait_event,
    EXTRACT(EPOCH FROM (now() - query_start)) AS query_duration_sec,
    EXTRACT(EPOCH FROM (now() - xact_start)) AS transaction_duration_sec,
    LEFT(query, 200) AS query_preview
FROM pg_stat_activity
WHERE state != 'idle'
    AND pid != pg_backend_pid()
    AND query NOT LIKE '%pg_stat_activity%'
ORDER BY query_start ASC;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '3.3. Long-running queries (over 30 seconds)'
\echo '----------------------------------------------------------------------------'

SELECT 
    pid,
    usename,
    application_name,
    client_addr,
    state,
    wait_event_type,
    wait_event,
    EXTRACT(EPOCH FROM (now() - query_start)) AS duration_sec,
    ROUND((EXTRACT(EPOCH FROM (now() - query_start)) / 60)::numeric, 2) AS duration_min,
    query_start,
    LEFT(query, 300) AS query_preview
FROM pg_stat_activity
WHERE state != 'idle'
    AND query_start < now() - INTERVAL '30 seconds'
    AND pid != pg_backend_pid()
    AND query NOT LIKE '%pg_stat_activity%'
ORDER BY query_start ASC;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '3.4. Long-running transactions (idle in transaction)'
\echo '----------------------------------------------------------------------------'

SELECT 
    pid,
    usename,
    application_name,
    client_addr,
    backend_start,
    xact_start,
    state_change,
    EXTRACT(EPOCH FROM (now() - xact_start)) AS transaction_age_sec,
    EXTRACT(EPOCH FROM (now() - state_change)) AS idle_age_sec,
    state,
    LEFT(query, 200) AS last_query
FROM pg_stat_activity
WHERE state LIKE '%transaction%'
    AND xact_start IS NOT NULL
    AND pid != pg_backend_pid()
ORDER BY xact_start ASC;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '3.5. Kill long-running query (use PID from above queries)'
\echo '----------------------------------------------------------------------------'
/* Example: SELECT pg_cancel_backend(PID); */
/* Example: SELECT pg_terminate_backend(PID); */

\echo ''
\echo '============================================================================'
\echo 'PART 4: INDEXES ANALYSIS - COMPREHENSIVE INDEX ANALYSIS'
\echo '============================================================================'
\echo ''

\echo '----------------------------------------------------------------------------'
\echo '4.1. List of all indexes with usage statistics'
\echo '----------------------------------------------------------------------------'

SELECT
    schemaname,
    relname,
    indexrelname AS indexname,
    idx_scan,
    idx_tup_read,
    idx_tup_fetch,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||relname)) AS table_size,
    ROUND((100.0 * pg_relation_size(indexrelid) / 
           NULLIF(pg_total_relation_size(schemaname||'.'||relname), 0))::numeric, 2) AS index_to_table_ratio
FROM pg_stat_user_indexes
ORDER BY pg_relation_size(indexrelid) DESC;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '4.2. Unused indexes (candidates for removal)'
\echo '----------------------------------------------------------------------------'

SELECT
    schemaname,
    relname,
    indexrelname AS indexname,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    idx_scan,
    pg_get_indexdef(indexrelid) AS index_definition
FROM pg_stat_user_indexes
WHERE idx_scan = 0
    AND indexrelid NOT IN (
        SELECT indexrelid 
        FROM pg_index 
        WHERE indisunique = true OR indisprimary = true
    )
ORDER BY pg_relation_size(indexrelid) DESC;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '4.3. Indexes with low usage ratio'
\echo '----------------------------------------------------------------------------'

SELECT
    schemaname,
    relname,
    indexrelname AS indexname,
    idx_scan,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    CASE 
        WHEN idx_scan = 0 THEN 'Never used'
        WHEN idx_scan < 10 THEN 'Very low'
        WHEN idx_scan < 100 THEN 'Low'
        ELSE 'Normal'
    END AS usage_category,
    pg_get_indexdef(indexrelid) AS index_definition
FROM pg_stat_user_indexes
WHERE idx_scan < 100
ORDER BY idx_scan ASC, pg_relation_size(indexrelid) DESC
LIMIT 30;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '4.4. Potentially duplicate indexes'
\echo '----------------------------------------------------------------------------'

WITH index_details AS (
    SELECT
        schemaname,
        relname,
        indexrelname AS indexname,
        pg_get_indexdef(indexrelid) AS index_def,
        regexp_replace(pg_get_indexdef(indexrelid), '.*\((.*)\)', '\1') AS columns,
        pg_relation_size(indexrelid) AS index_size
    FROM pg_stat_user_indexes
)
SELECT
    a.schemaname,
    a.relname,
    a.indexname AS index1,
    b.indexname AS index2,
    a.columns AS columns1,
    b.columns AS columns2,
    pg_size_pretty(a.index_size) AS index1_size,
    pg_size_pretty(b.index_size) AS index2_size,
    CASE
        WHEN a.columns = b.columns THEN 'Exact duplicate'
        WHEN a.columns LIKE b.columns || '%' THEN 'Redundant (index1 extends index2)'
        WHEN b.columns LIKE a.columns || '%' THEN 'Redundant (index2 extends index1)'
        ELSE 'Similar'
    END AS relationship
FROM index_details a
JOIN index_details b ON 
    a.schemaname = b.schemaname 
    AND a.relname = b.relname 
    AND a.indexname < b.indexname
    AND (
        a.columns = b.columns 
        OR a.columns LIKE b.columns || '%' 
        OR b.columns LIKE a.columns || '%'
    )
ORDER BY a.relname, a.indexname;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '4.5. Tables without any indexes (except PK)'
\echo '----------------------------------------------------------------------------'

SELECT
    schemaname,
    relname,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||relname)) AS total_size,
    n_live_tup AS row_count_estimate,
    seq_scan,
    seq_tup_read
FROM pg_stat_user_tables t
WHERE NOT EXISTS (
    SELECT 1 
    FROM pg_stat_user_indexes i 
    WHERE i.schemaname = t.schemaname 
        AND i.relname = t.relname
        AND i.indexrelid NOT IN (
            SELECT indexrelid FROM pg_index WHERE indisprimary = true
        )
)
ORDER BY pg_total_relation_size(schemaname||'.'||relname) DESC;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '4.6. Index bloat estimation'
\echo '----------------------------------------------------------------------------'

SELECT
    s.schemaname,
    s.relname,
    s.indexrelname AS indexname,
    pg_size_pretty(pg_relation_size(s.indexrelid)) AS index_size,
    s.idx_scan,
    pg_size_pretty(pg_total_relation_size(s.schemaname||'.'||s.relname)) AS table_size
FROM pg_stat_user_indexes s
WHERE pg_relation_size(s.indexrelid) > 1024 * 1024
ORDER BY pg_relation_size(s.indexrelid) DESC
LIMIT 30;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '4.7. Missing indexes - tables with high seq_scan ratio'
\echo '----------------------------------------------------------------------------'

SELECT
    schemaname,
    relname,
    seq_scan,
    seq_tup_read,
    idx_scan,
    ROUND((100.0 * seq_scan / NULLIF(seq_scan + idx_scan, 0))::numeric, 2) AS seq_scan_pct,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||relname)) AS table_size,
    n_live_tup AS estimated_rows
FROM pg_stat_user_tables
WHERE (seq_scan + idx_scan) > 0
    AND n_live_tup > 1000
ORDER BY seq_scan DESC, seq_tup_read DESC
LIMIT 20;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '4.8. Index health summary per table'
\echo '----------------------------------------------------------------------------'

SELECT
    t.schemaname,
    t.relname,
    pg_size_pretty(pg_total_relation_size(t.schemaname||'.'||t.relname)) AS table_size,
    COUNT(i.indexrelname) AS index_count,
    pg_size_pretty(SUM(pg_relation_size(i.indexrelid))) AS total_index_size,
    ROUND(AVG(i.idx_scan)::numeric, 2) AS avg_index_scans,
    t.seq_scan,
    t.idx_scan AS table_idx_scan
FROM pg_stat_user_tables t
LEFT JOIN pg_stat_user_indexes i ON t.schemaname = i.schemaname AND t.relname = i.relname
GROUP BY t.schemaname, t.relname, t.seq_scan, t.idx_scan
ORDER BY pg_total_relation_size(t.schemaname||'.'||t.relname) DESC
LIMIT 30;

\echo ''
\echo '============================================================================'
\echo 'PART 5: DATABASE PARAMETERS - CONFIGURATION ANALYSIS'
\echo '============================================================================'
\echo ''

\echo '----------------------------------------------------------------------------'
\echo '5.1. Key performance parameters'
\echo '----------------------------------------------------------------------------'

SELECT 
    name,
    setting,
    unit,
    category,
    short_desc,
    source,
    sourcefile
FROM pg_settings
WHERE name IN (
    'max_connections',
    'shared_buffers',
    'effective_cache_size',
    'maintenance_work_mem',
    'work_mem',
    'checkpoint_completion_target',
    'checkpoint_timeout',
    'max_wal_size',
    'min_wal_size',
    'wal_buffers',
    'default_statistics_target',
    'random_page_cost',
    'effective_io_concurrency',
    'max_worker_processes',
    'max_parallel_workers_per_gather',
    'max_parallel_workers',
    'autovacuum',
    'autovacuum_max_workers',
    'autovacuum_naptime'
)
ORDER BY name;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '5.2. All parameters changed from default values'
\echo '----------------------------------------------------------------------------'

SELECT 
    name, 
    setting, 
    unit,
    boot_val AS default_value,
    reset_val AS current_value,
    source,
    sourcefile
FROM pg_settings
WHERE source NOT IN ('default', 'override')
ORDER BY category, name;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '5.3. Checkpoint statistics'
\echo '----------------------------------------------------------------------------'

SELECT 
    num_timed AS checkpoints_timed,
    num_requested AS checkpoints_req,
    write_time AS checkpoint_write_time_ms,
    sync_time AS checkpoint_sync_time_ms,
    buffers_written,
    ROUND((100.0 * num_requested / NULLIF(num_timed + num_requested, 0))::numeric, 2) AS checkpoint_req_pct,
    ROUND((write_time::numeric / NULLIF(num_timed + num_requested, 0)), 2) AS avg_write_time_ms,
    ROUND((sync_time::numeric / NULLIF(num_timed + num_requested, 0)), 2) AS avg_sync_time_ms
FROM pg_stat_checkpointer;


\echo ''
\echo '----------------------------------------------------------------------------'
\echo '5.4. Connection statistics'
\echo '----------------------------------------------------------------------------'

SELECT 
    datname,
    numbackends AS current_connections,
    xact_commit,
    xact_rollback,
    ROUND((100.0 * xact_rollback / NULLIF(xact_commit + xact_rollback, 0))::numeric, 2) AS rollback_pct,
    blks_read,
    blks_hit,
    ROUND((100.0 * blks_hit / NULLIF(blks_read + blks_hit, 0))::numeric, 2) AS cache_hit_ratio,
    tup_returned,
    tup_fetched,
    tup_inserted,
    tup_updated,
    tup_deleted,
    conflicts,
    deadlocks
FROM pg_stat_database
WHERE datname NOT IN ('template0', 'template1')
ORDER BY numbackends DESC;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '5.5. Detailed connection pool analysis'
\echo '----------------------------------------------------------------------------'

SELECT 
    state,
    COUNT(*) AS count,
    MAX(EXTRACT(EPOCH FROM (now() - state_change))) AS max_duration_sec
FROM pg_stat_activity
WHERE pid != pg_backend_pid()
GROUP BY state
ORDER BY count DESC;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '5.6. Connection state breakdown by database and user'
\echo '----------------------------------------------------------------------------'

SELECT 
    datname,
    usename,
    state,
    COUNT(*) AS connection_count,
    MAX(EXTRACT(EPOCH FROM (now() - backend_start))) AS oldest_connection_sec
FROM pg_stat_activity
WHERE pid != pg_backend_pid()
GROUP BY datname, usename, state
ORDER BY connection_count DESC;

\echo ''
\echo '============================================================================'
\echo 'PART 6: BLOCKING SESSIONS - LOCK ANALYSIS'
\echo '============================================================================'
\echo ''

\echo '----------------------------------------------------------------------------'
\echo '6.1. Active locks (who is blocking whom)'
\echo '----------------------------------------------------------------------------'

SELECT 
    blocked_locks.pid AS blocked_pid,
    blocked_activity.usename AS blocked_user,
    blocked_activity.application_name AS blocked_app,
    blocking_locks.pid AS blocking_pid,
    blocking_activity.usename AS blocking_user,
    blocking_activity.application_name AS blocking_app,
    blocked_activity.query AS blocked_statement,
    blocking_activity.query AS blocking_statement,
    EXTRACT(EPOCH FROM (now() - blocked_activity.query_start)) AS blocked_duration_sec,
    EXTRACT(EPOCH FROM (now() - blocking_activity.query_start)) AS blocking_duration_sec
FROM pg_catalog.pg_locks blocked_locks
JOIN pg_catalog.pg_stat_activity blocked_activity ON blocked_activity.pid = blocked_locks.pid
JOIN pg_catalog.pg_locks blocking_locks 
    ON blocking_locks.locktype = blocked_locks.locktype
    AND blocking_locks.database IS NOT DISTINCT FROM blocked_locks.database
    AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation
    AND blocking_locks.page IS NOT DISTINCT FROM blocked_locks.page
    AND blocking_locks.tuple IS NOT DISTINCT FROM blocked_locks.tuple
    AND blocking_locks.virtualxid IS NOT DISTINCT FROM blocked_locks.virtualxid
    AND blocking_locks.transactionid IS NOT DISTINCT FROM blocked_locks.transactionid
    AND blocking_locks.classid IS NOT DISTINCT FROM blocked_locks.classid
    AND blocking_locks.objid IS NOT DISTINCT FROM blocked_locks.objid
    AND blocking_locks.objsubid IS NOT DISTINCT FROM blocked_locks.objsubid
    AND blocking_locks.pid != blocked_locks.pid
JOIN pg_catalog.pg_stat_activity blocking_activity ON blocking_activity.pid = blocking_locks.pid
WHERE NOT blocked_locks.granted
ORDER BY blocked_duration_sec DESC;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '6.2. Lock tree (lock hierarchy)'
\echo '----------------------------------------------------------------------------'

WITH RECURSIVE lock_chain AS (
    SELECT 
        pid,
        locktype,
        relation::regclass AS relation,
        mode,
        granted,
        ARRAY[pid] AS chain,
        1 AS depth
    FROM pg_locks
    WHERE NOT granted
    
    UNION ALL
    
    SELECT 
        l.pid,
        l.locktype,
        l.relation::regclass,
        l.mode,
        l.granted,
        lc.chain || l.pid,
        lc.depth + 1
    FROM pg_locks l
    JOIN lock_chain lc ON l.pid = ANY(
        SELECT blocking.pid
        FROM pg_locks blocked
        JOIN pg_locks blocking ON (
            blocking.locktype = blocked.locktype AND
            blocking.database IS NOT DISTINCT FROM blocked.database AND
            blocking.relation IS NOT DISTINCT FROM blocked.relation AND
            blocking.page IS NOT DISTINCT FROM blocked.page AND
            blocking.tuple IS NOT DISTINCT FROM blocked.tuple AND
            blocking.virtualxid IS NOT DISTINCT FROM blocked.virtualxid AND
            blocking.transactionid IS NOT DISTINCT FROM blocked.transactionid AND
            blocking.classid IS NOT DISTINCT FROM blocked.classid AND
            blocking.objid IS NOT DISTINCT FROM blocked.objid AND
            blocking.objsubid IS NOT DISTINCT FROM blocked.objsubid AND
            blocking.pid != blocked.pid
        )
        WHERE blocked.pid = lc.pid AND NOT blocked.granted AND blocking.granted
    )
    WHERE lc.depth < 10
)
SELECT 
    depth,
    pid,
    locktype,
    relation,
    mode,
    granted,
    chain,
    (SELECT query FROM pg_stat_activity WHERE pg_stat_activity.pid = lock_chain.pid) AS query
FROM lock_chain
ORDER BY chain, depth;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '6.3. All active locks in the system'
\echo '----------------------------------------------------------------------------'

SELECT 
    l.locktype,
    l.database,
    l.relation::regclass AS relation,
    l.page,
    l.tuple,
    l.virtualxid,
    l.transactionid,
    l.classid,
    l.objid,
    l.objsubid,
    l.virtualtransaction,
    l.pid,
    l.mode,
    l.granted,
    a.usename,
    a.application_name,
    a.client_addr,
    a.query_start,
    EXTRACT(EPOCH FROM (now() - a.query_start)) AS query_duration_sec,
    LEFT(a.query, 100) AS query_preview
FROM pg_locks l
LEFT JOIN pg_stat_activity a ON l.pid = a.pid
WHERE l.pid IS NOT NULL
ORDER BY l.granted, query_duration_sec DESC NULLS LAST;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '6.4. Deadlock history (from logs - requires log_lock_waits = on)'
\echo 'Deadlocks are recorded in PostgreSQL logs'
\echo 'On GCP Cloud SQL they can be viewed in Cloud Logging'
\echo '----------------------------------------------------------------------------'

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '6.5. Lock contention summary'
\echo '----------------------------------------------------------------------------'

SELECT 
    relation::regclass AS table_name,
    locktype,
    mode,
    COUNT(*) AS lock_count,
    COUNT(*) FILTER (WHERE NOT granted) AS waiting_count,
    COUNT(*) FILTER (WHERE granted) AS granted_count
FROM pg_locks
WHERE relation IS NOT NULL
GROUP BY relation, locktype, mode
HAVING COUNT(*) FILTER (WHERE NOT granted) > 0
ORDER BY waiting_count DESC, lock_count DESC;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '6.6. Transactions holding locks the longest'
\echo '----------------------------------------------------------------------------'

SELECT 
    a.pid,
    a.usename,
    a.application_name,
    a.client_addr,
    a.backend_start,
    a.xact_start,
    EXTRACT(EPOCH FROM (now() - a.xact_start)) AS transaction_age_sec,
    a.state,
    COUNT(l.*) AS locks_held,
    LEFT(a.query, 200) AS query_preview
FROM pg_stat_activity a
LEFT JOIN pg_locks l ON a.pid = l.pid AND l.granted
WHERE a.xact_start IS NOT NULL
GROUP BY a.pid, a.usename, a.application_name, a.client_addr, 
         a.backend_start, a.xact_start, a.state, a.query
ORDER BY transaction_age_sec DESC
LIMIT 20;

\echo ''
\echo '============================================================================'
\echo 'PART 7: RESOURCE UTILIZATION - RESOURCE MONITORING'
\echo '============================================================================'
\echo ''

\echo '----------------------------------------------------------------------------'
\echo '7.1. Database size overview'
\echo '----------------------------------------------------------------------------'

SELECT 
    datname,
    pg_size_pretty(pg_database_size(datname)) AS database_size,
    numbackends AS active_connections
FROM pg_stat_database
WHERE datname NOT IN ('template0', 'template1', 'postgres')
ORDER BY pg_database_size(datname) DESC;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '7.2. Largest tables'
\echo '----------------------------------------------------------------------------'

SELECT
    schemaname,
    relname AS relname,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||relname)) AS total_size,
    pg_size_pretty(pg_relation_size(schemaname||'.'||relname)) AS table_size,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||relname) - 
                   pg_relation_size(schemaname||'.'||relname)) AS indexes_size,
    n_live_tup AS estimated_rows,
    n_dead_tup AS dead_rows,
    ROUND((100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0))::numeric, 2) AS dead_row_pct,
    last_vacuum,
    last_autovacuum,
    last_analyze,
    last_autoanalyze
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(schemaname||'.'||relname) DESC
LIMIT 30;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '7.3. Table I/O statistics'
\echo '----------------------------------------------------------------------------'

SELECT
    schemaname,
    relname AS relname,
    heap_blks_read,
    heap_blks_hit,
    ROUND((100.0 * heap_blks_hit / NULLIF(heap_blks_read + heap_blks_hit, 0))::numeric, 2) AS heap_hit_ratio,
    idx_blks_read,
    idx_blks_hit,
    ROUND((100.0 * idx_blks_hit / NULLIF(idx_blks_read + idx_blks_hit, 0))::numeric, 2) AS index_hit_ratio,
    toast_blks_read,
    toast_blks_hit,
    tidx_blks_read,
    tidx_blks_hit
FROM pg_statio_user_tables
WHERE (heap_blks_read + heap_blks_hit) > 0
ORDER BY (heap_blks_read + idx_blks_read) DESC
LIMIT 30;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '7.4. Cache hit ratio per database'
\echo '----------------------------------------------------------------------------'

SELECT
    datname,
    blks_read AS disk_reads,
    blks_hit AS cache_hits,
    blks_read + blks_hit AS total_reads,
    ROUND((100.0 * blks_hit / NULLIF(blks_read + blks_hit, 0))::numeric, 2) AS cache_hit_ratio
FROM pg_stat_database
WHERE datname NOT IN ('template0', 'template1')
ORDER BY cache_hit_ratio ASC;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '7.5. Disk usage per tablespace'
\echo '----------------------------------------------------------------------------'

SELECT 
    spcname AS tablespace_name,
    pg_size_pretty(pg_tablespace_size(spcname)) AS size
FROM pg_tablespace
ORDER BY pg_tablespace_size(spcname) DESC;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '7.6. WAL generation rate'
\echo '----------------------------------------------------------------------------'

SELECT
    pg_current_wal_lsn(),
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0')) AS total_wal_generated;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '7.7. Temporary file usage'
\echo '----------------------------------------------------------------------------'

SELECT 
    datname,
    temp_files,
    pg_size_pretty(temp_bytes) AS temp_size,
    ROUND((temp_bytes::numeric / NULLIF(temp_files, 0) / 1024 / 1024), 2) AS avg_temp_file_mb
FROM pg_stat_database
WHERE temp_files > 0
ORDER BY temp_bytes DESC;

\echo ''
\echo '============================================================================'
\echo 'PART 8: MEMORY OPTIMIZATION - MEMORY ANALYSIS'
\echo '============================================================================'
\echo ''

\echo '----------------------------------------------------------------------------'
\echo '8.1. Shared buffers usage (requires pg_buffercache extension)'
CREATE EXTENSION IF NOT EXISTS pg_buffercache;
\echo '----------------------------------------------------------------------------'

SELECT
    c.relname,
    count(*) AS buffers,
    pg_size_pretty(count(*) * 8192) AS size_in_cache
FROM pg_buffercache b
INNER JOIN pg_class c ON b.relfilenode = pg_relation_filenode(c.oid)
    AND b.reldatabase IN (0, (SELECT oid FROM pg_database WHERE datname = current_database()))
WHERE c.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
GROUP BY c.relname
ORDER BY count(*) DESC
LIMIT 20;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '8.2. Buffer cache summary'
\echo '----------------------------------------------------------------------------'

SELECT
    COUNT(*) * 8192 / 1024 / 1024 AS total_cached_mb,
    SUM(CASE WHEN isdirty THEN 1 ELSE 0 END) * 8192 / 1024 / 1024 AS dirty_mb,
    ROUND((100.0 * SUM(CASE WHEN isdirty THEN 1 ELSE 0 END) / COUNT(*))::numeric, 2) AS dirty_pct
FROM pg_buffercache;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '8.3. Top memory-consuming queries (work_mem usage)'
\echo '----------------------------------------------------------------------------'

SELECT 
    queryid,
    LEFT(query, 100) AS query_preview,
    calls,
    temp_blks_written,
    pg_size_pretty(temp_blks_written * 8192) AS temp_data_written,
    ROUND(mean_exec_time::numeric, 2) AS avg_time_ms,
    CASE 
        WHEN temp_blks_written > 1000000 THEN 'Very High'
        WHEN temp_blks_written > 100000 THEN 'High'
        WHEN temp_blks_written > 10000 THEN 'Medium'
        ELSE 'Low'
    END AS memory_pressure
FROM pg_stat_statements
WHERE temp_blks_written > 0
ORDER BY temp_blks_written DESC
LIMIT 20;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '8.4. Memory context usage per backend'
\echo '----------------------------------------------------------------------------'

SELECT
    pid,
    usename,
    application_name,
    state,
    backend_type,
    EXTRACT(EPOCH FROM (now() - backend_start)) AS uptime_sec,
    EXTRACT(EPOCH FROM (now() - query_start)) AS query_duration_sec
FROM pg_stat_activity
WHERE backend_type != 'background writer'
ORDER BY backend_start ASC;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '8.5. work_mem recommendations (based on temp usage)'
\echo '----------------------------------------------------------------------------'

WITH temp_usage AS (
    SELECT 
        queryid,
        calls,
        temp_blks_written,
        (temp_blks_written * 8192.0 / 1024 / 1024 / calls) AS avg_temp_mb_per_call
    FROM pg_stat_statements
    WHERE temp_blks_written > 0 AND calls > 0
)
SELECT 
    COUNT(*) AS queries_using_temp,
    ROUND(AVG(avg_temp_mb_per_call)::numeric, 2) AS avg_temp_mb,
    ROUND(MAX(avg_temp_mb_per_call)::numeric, 2) AS max_temp_mb,
    ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY avg_temp_mb_per_call)::numeric, 2) AS p95_temp_mb,
    pg_size_pretty((PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY avg_temp_mb_per_call) * 1024 * 1024)::bigint) AS recommended_work_mem
FROM temp_usage;

\echo ''
\echo '============================================================================'
\echo 'PART 9: QUERY EXECUTION TIMES AND FREQUENCY (Query Insights)'
\echo '============================================================================'
\echo ''

\echo '----------------------------------------------------------------------------'
\echo '9.1. Query frequency analysis'
\echo '----------------------------------------------------------------------------'

SELECT 
    queryid,
    calls,
    ROUND((100.0 * calls / SUM(calls) OVER ())::numeric, 2) AS call_pct,
    ROUND(mean_exec_time::numeric, 2) AS avg_ms,
    ROUND(total_exec_time::numeric, 2) AS total_ms,
    pg_size_pretty((calls * 1024)::bigint) AS estimated_bandwidth,
    LEFT(query, 100) AS query_preview
FROM pg_stat_statements
WHERE query NOT LIKE '%pg_stat_statements%'
ORDER BY calls DESC
LIMIT 20;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '9.2. Query patterns - grouped by similar execution time'
\echo '----------------------------------------------------------------------------'

SELECT 
    CASE 
        WHEN mean_exec_time < 1 THEN '< 1ms (Very Fast)'
        WHEN mean_exec_time < 10 THEN '1-10ms (Fast)'
        WHEN mean_exec_time < 100 THEN '10-100ms (Moderate)'
        WHEN mean_exec_time < 1000 THEN '100ms-1s (Slow)'
        WHEN mean_exec_time < 10000 THEN '1-10s (Very Slow)'
        ELSE '> 10s (Extremely Slow)'
    END AS performance_category,
    COUNT(*) AS query_count,
    SUM(calls) AS total_calls,
    ROUND(AVG(mean_exec_time)::numeric, 2) AS avg_exec_time_ms,
    pg_size_pretty(SUM(total_exec_time * 1024)::bigint) AS total_time_consumed
FROM pg_stat_statements
WHERE query NOT LIKE '%pg_stat_statements%'
GROUP BY performance_category
ORDER BY avg_exec_time_ms DESC;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '9.3. Time-based distribution of queries'
\echo '----------------------------------------------------------------------------'

SELECT 
    queryid,
    calls,
    ROUND(min_exec_time::numeric, 2) AS min_ms,
    ROUND((PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY mean_exec_time))::numeric, 2) AS p25_ms,
    ROUND(mean_exec_time::numeric, 2) AS median_ms,
    ROUND((PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY mean_exec_time))::numeric, 2) AS p75_ms,
    ROUND((PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY mean_exec_time))::numeric, 2) AS p95_ms,
    ROUND((PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY mean_exec_time))::numeric, 2) AS p99_ms,
    ROUND(max_exec_time::numeric, 2) AS max_ms,
    LEFT(query, 80) AS query_preview
FROM pg_stat_statements
WHERE calls > 10
    AND query NOT LIKE '%pg_stat_statements%'
GROUP BY queryid, query, calls, min_exec_time, mean_exec_time, max_exec_time
ORDER BY mean_exec_time DESC
LIMIT 20;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '9.4. Query execution timeline (buckets)'
\echo '----------------------------------------------------------------------------'

SELECT 
    date_trunc('hour', now()) AS time_bucket,
    COUNT(DISTINCT queryid) AS unique_queries,
    SUM(calls) AS total_executions
FROM pg_stat_statements
WHERE query NOT LIKE '%pg_stat_statements%'
GROUP BY time_bucket
ORDER BY time_bucket DESC;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '9.5. Rows processed vs returned ratio'
\echo '----------------------------------------------------------------------------'

SELECT 
    queryid,
    calls,
    rows,
    ROUND((rows::numeric / NULLIF(calls, 0)), 2) AS avg_rows_per_call,
    ROUND(mean_exec_time::numeric, 2) AS avg_ms,
    CASE 
        WHEN rows / NULLIF(calls, 0) > 10000 THEN 'High volume'
        WHEN rows / NULLIF(calls, 0) > 1000 THEN 'Medium volume'
        WHEN rows / NULLIF(calls, 0) > 100 THEN 'Low volume'
        ELSE 'Very low volume'
    END AS data_volume_category,
    LEFT(query, 100) AS query_preview
FROM pg_stat_statements
WHERE calls > 0
    AND query NOT LIKE '%pg_stat_statements%'
ORDER BY (rows::numeric / NULLIF(calls, 0)) DESC
LIMIT 20;

\echo ''
\echo '============================================================================'
\echo 'PART 10: DATABASE STATISTICS & MAINTENANCE'
\echo '============================================================================'
\echo ''

\echo '----------------------------------------------------------------------------'
\echo '10.1. Vacuum and Analyze history'
\echo '----------------------------------------------------------------------------'

SELECT
    schemaname,
    relname,
    last_vacuum,
    last_autovacuum,
    COALESCE(last_vacuum, last_autovacuum) AS last_vacuum_any,
    EXTRACT(EPOCH FROM (now() - COALESCE(last_vacuum, last_autovacuum))) / 3600 AS hours_since_vacuum,
    last_analyze,
    last_autoanalyze,
    COALESCE(last_analyze, last_autoanalyze) AS last_analyze_any,
    EXTRACT(EPOCH FROM (now() - COALESCE(last_analyze, last_autoanalyze))) / 3600 AS hours_since_analyze,
    vacuum_count,
    autovacuum_count,
    analyze_count,
    autoanalyze_count
FROM pg_stat_user_tables
ORDER BY hours_since_vacuum DESC NULLS FIRST
LIMIT 30;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '10.2. Table bloat estimation (method 1 - quick)'
\echo '----------------------------------------------------------------------------'

SELECT
    schemaname,
    relname,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||relname)) AS total_size,
    n_live_tup,
    n_dead_tup,
    ROUND((100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0))::numeric, 2) AS dead_tuple_pct,
    CASE
        WHEN n_dead_tup > 1000000 THEN 'Critical'
        WHEN n_dead_tup > 100000 THEN 'High'
        WHEN n_dead_tup > 10000 THEN 'Medium'
        ELSE 'Low'
    END AS bloat_level,
    last_vacuum,
    last_autovacuum
FROM pg_stat_user_tables
WHERE n_dead_tup > 0
ORDER BY n_dead_tup DESC
LIMIT 30;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '10.3. Table bloat estimation (method 2 - detailed, uses pgstattuple)'
\echo 'WARNING: This query can be expensive for large tables'
\echo '----------------------------------------------------------------------------'

SELECT
    schemaname,
    tablename AS relname,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS total_size,
    pg_size_pretty(table_len) AS table_len,
    pg_size_pretty(tuple_len) AS tuple_len,
    pg_size_pretty(dead_tuple_len) AS dead_tuple_len,
    ROUND(dead_tuple_percent::numeric, 2) AS dead_tuple_pct,
    pg_size_pretty(free_space) AS free_space,
    ROUND(free_percent::numeric, 2) AS free_pct
FROM (
    SELECT 
        t.schemaname,
        t.tablename,
        (pgstattuple(t.schemaname||'.'||t.tablename)).*
    FROM pg_tables t
    WHERE t.schemaname = 'public'
    AND pg_total_relation_size(t.schemaname||'.'||t.tablename) > 10485760
    LIMIT 10
) AS bloat_data
ORDER BY dead_tuple_percent DESC;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '10.4. Autovacuum settings per table'
\echo '----------------------------------------------------------------------------'

SELECT
    n.nspname AS schema_name,
    c.relname AS table_name,
    c.reloptions AS table_settings,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
    AND n.nspname NOT IN ('pg_catalog', 'information_schema')
    AND c.reloptions IS NOT NULL
ORDER BY pg_total_relation_size(c.oid) DESC;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '10.5. Tables requiring immediate VACUUM'
\echo '----------------------------------------------------------------------------'

SELECT
    schemaname,
    relname AS relname,
    n_live_tup,
    n_dead_tup,
    ROUND((100.0 * n_dead_tup / NULLIF(n_live_tup, 0))::numeric, 2) AS dead_pct,
    last_vacuum,
    last_autovacuum,
    EXTRACT(EPOCH FROM (now() - COALESCE(last_vacuum, last_autovacuum))) / 86400 AS days_since_vacuum,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||relname)) AS size,
    'VACUUM ANALYZE ' || schemaname || '.' || relname || ';' AS vacuum_command
FROM pg_stat_user_tables
WHERE n_dead_tup > n_live_tup * 0.1
    OR (COALESCE(last_vacuum, last_autovacuum) < now() - INTERVAL '7 days')
    OR (n_dead_tup > 100000)
ORDER BY n_dead_tup DESC
LIMIT 20;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '10.6. Statistics staleness check'
\echo '----------------------------------------------------------------------------'

SELECT
    schemaname,
    relname AS relname,
    n_mod_since_analyze,
    n_live_tup,
    ROUND((100.0 * n_mod_since_analyze / NULLIF(n_live_tup, 0))::numeric, 2) AS modification_pct,
    last_analyze,
    last_autoanalyze,
    EXTRACT(EPOCH FROM (now() - COALESCE(last_analyze, last_autoanalyze))) / 86400 AS days_since_analyze,
    CASE
        WHEN n_mod_since_analyze > n_live_tup * 0.2 THEN 'Critical - Run ANALYZE'
        WHEN n_mod_since_analyze > n_live_tup * 0.1 THEN 'High - Consider ANALYZE'
        WHEN COALESCE(last_analyze, last_autoanalyze) < now() - INTERVAL '7 days' THEN 'Stale statistics'
        ELSE 'OK'
    END AS recommendation,
    'ANALYZE ' || schemaname || '.' || relname || ';' AS analyze_command
FROM pg_stat_user_tables
WHERE n_mod_since_analyze > 0
ORDER BY modification_pct DESC NULLS LAST
LIMIT 30;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '10.7. Fragmentation indicators'
\echo '----------------------------------------------------------------------------'

SELECT
    schemaname,
    relname AS relname,
    seq_scan,
    seq_tup_read,
    idx_scan,
    CASE 
        WHEN seq_scan = 0 THEN NULL
        ELSE ROUND((seq_tup_read::numeric / seq_scan), 2)
    END AS avg_tup_per_seq_scan,
    n_tup_ins + n_tup_upd + n_tup_del AS total_modifications,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||relname)) AS size,
    last_vacuum,
    CASE
        WHEN (n_tup_ins + n_tup_upd + n_tup_del) > 1000000 
             AND last_vacuum < now() - INTERVAL '3 days' THEN 'High fragmentation risk'
        WHEN (n_tup_ins + n_tup_upd + n_tup_del) > 500000 
             AND last_vacuum < now() - INTERVAL '7 days' THEN 'Medium fragmentation risk'
        ELSE 'Low risk'
    END AS fragmentation_risk
FROM pg_stat_user_tables
WHERE (n_tup_ins + n_tup_upd + n_tup_del) > 0
ORDER BY total_modifications DESC
LIMIT 20;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '10.8. Autovacuum activity monitoring'
\echo '----------------------------------------------------------------------------'

SELECT
    datname,
    usename,
    pid,
    backend_start,
    query_start,
    EXTRACT(EPOCH FROM (now() - query_start)) AS duration_sec,
    state,
    wait_event_type,
    wait_event,
    LEFT(query, 200) AS query
FROM pg_stat_activity
WHERE query LIKE '%autovacuum%'
    AND query NOT LIKE '%pg_stat_activity%'
ORDER BY query_start;

\echo ''
\echo '============================================================================'
\echo 'PART 11: MAINTENANCE COMMANDS - OPTIMIZATION ACTIONS'
\echo '============================================================================'
\echo ''

\echo '----------------------------------------------------------------------------'
\echo '11.1. Manual VACUUM examples (run for selected tables)'
\echo '----------------------------------------------------------------------------'
/* VACUUM ANALYZE schema_name.table_name; */
/* VACUUM (FULL, ANALYZE, VERBOSE) schema_name.table_name; */

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '11.2. Manual ANALYZE'
\echo '----------------------------------------------------------------------------'
/* ANALYZE schema_name.table_name; */
/* ANALYZE; */

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '11.3. REINDEX for degraded indexes'
\echo '----------------------------------------------------------------------------'
/* REINDEX INDEX index_name; */
/* REINDEX TABLE table_name; */
/* REINDEX SCHEMA public; */

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '11.4. Update table statistics target'
\echo '----------------------------------------------------------------------------'
/* ALTER TABLE table_name ALTER COLUMN column_name SET STATISTICS 1000; */

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '11.5. Increase autovacuum frequency for specific table'
\echo '----------------------------------------------------------------------------'
/*
ALTER TABLE table_name SET (
    autovacuum_vacuum_scale_factor = 0.05,
    autovacuum_analyze_scale_factor = 0.02,
    autovacuum_vacuum_threshold = 100,
    autovacuum_analyze_threshold = 100
);
*/

\echo ''
\echo '============================================================================'
\echo 'PART 12: RECOMMENDATIONS AND SUMMARY'
\echo '============================================================================'
\echo ''

\echo '----------------------------------------------------------------------------'
\echo '12.1. Quick health check summary'
\echo '----------------------------------------------------------------------------'

SELECT
    'Total Connections' AS metric,
    COUNT(*)::text AS value
FROM pg_stat_activity
WHERE pid != pg_backend_pid()

UNION ALL

SELECT
    'Active Queries',
    COUNT(*)::text
FROM pg_stat_activity
WHERE state = 'active' AND pid != pg_backend_pid()

UNION ALL

SELECT
    'Long Running (>5min)',
    COUNT(*)::text
FROM pg_stat_activity
WHERE state = 'active' 
    AND query_start < now() - INTERVAL '5 minutes'
    AND pid != pg_backend_pid()

UNION ALL

SELECT
    'Idle in Transaction',
    COUNT(*)::text
FROM pg_stat_activity
WHERE state LIKE '%transaction%'

UNION ALL

SELECT
    'Active Locks',
    COUNT(*)::text
FROM pg_locks
WHERE NOT granted

UNION ALL

SELECT
    'Tables Needing VACUUM',
    COUNT(*)::text
FROM pg_stat_user_tables
WHERE n_dead_tup > n_live_tup * 0.1

UNION ALL

SELECT
    'Unused Indexes',
    COUNT(*)::text
FROM pg_stat_user_indexes
WHERE idx_scan = 0
    AND indexrelid NOT IN (SELECT indexrelid FROM pg_index WHERE indisprimary OR indisunique)

UNION ALL

SELECT
    'Cache Hit Ratio',
    ROUND((100.0 * SUM(blks_hit) / NULLIF(SUM(blks_hit) + SUM(blks_read), 0))::numeric, 2)::text || '%'
FROM pg_stat_database;

\echo ''
\echo '============================================================================'
\echo 'Priority actions checklist'
\echo 'After completing all analyses, execute actions in order:'
\echo '1. Terminate blocking sessions (if any)'
\echo '2. Run VACUUM ANALYZE on tables with high bloat'
\echo '3. Remove unused indexes'
\echo '4. Add missing indexes for frequently executed queries'
\echo '5. Increase work_mem for queries using many temp files'
\echo '6. Adjust checkpoint_completion_target if checkpoints_req > 20%'
\echo '7. Analyze and optimize top 10 slow queries'
\echo '============================================================================'
\echo ''
\echo 'END OF MONITORING PLAN'
\echo ''
