-- ============================================================================
-- PostgreSQL Comprehensive Health Check & Performance Report
-- Generic Version - pg_stat_statements 1.4 compatible
-- ============================================================================

\echo ''
\echo '╔══════════════════════════════════════════════════════════════════════════╗'
\echo '║        PostgreSQL Comprehensive Health Check & Performance Report        ║'
\echo '╚══════════════════════════════════════════════════════════════════════════╝'
\echo ''

-- ============================================================================
-- SECTION 1: Executive Summary
-- ============================================================================

\echo '============================================================================'
\echo 'SECTION 1: Executive Summary'
\echo '============================================================================'

-- 1.1 Database overview
\echo '-- 1.1 Database overview'
SELECT 
    current_database() AS database_name,
    current_user AS connected_as,
    version() AS postgres_version,
    pg_size_pretty(pg_database_size(current_database())) AS database_size,
    (SELECT count(*) FROM pg_stat_user_tables) AS user_tables,
    (SELECT count(*) FROM pg_stat_user_indexes) AS user_indexes,
    pg_postmaster_start_time() AS server_start_time,
    now() - pg_postmaster_start_time() AS uptime;

-- 1.2 Cache hit ratios
\echo '-- 1.2 Cache hit ratios'
SELECT 
    'Table Cache' AS cache_type,
    ROUND(100.0 * sum(heap_blks_hit) / nullif(sum(heap_blks_hit) + sum(heap_blks_read), 0), 2) AS hit_ratio_pct,
    pg_size_pretty(sum(heap_blks_read)::bigint * 8192) AS data_read_from_disk,
    pg_size_pretty(sum(heap_blks_hit)::bigint * 8192) AS data_read_from_cache
FROM pg_statio_user_tables
UNION ALL
SELECT 
    'Index Cache',
    ROUND(100.0 * sum(idx_blks_hit) / nullif(sum(idx_blks_hit) + sum(idx_blks_read), 0), 2),
    pg_size_pretty(sum(idx_blks_read)::bigint * 8192),
    pg_size_pretty(sum(idx_blks_hit)::bigint * 8192)
FROM pg_statio_user_indexes
UNION ALL
SELECT 
    'TOAST Cache',
    ROUND(100.0 * sum(toast_blks_hit) / nullif(sum(toast_blks_hit) + sum(toast_blks_read), 0), 2),
    pg_size_pretty(sum(toast_blks_read)::bigint * 8192),
    pg_size_pretty(sum(toast_blks_hit)::bigint * 8192)
FROM pg_statio_user_tables
WHERE toast_blks_read > 0 OR toast_blks_hit > 0;

-- 1.3 Connection statistics
\echo '-- 1.3 Connection statistics'
SELECT 
    count(*) AS total_connections,
    count(*) FILTER (WHERE state = 'active') AS active,
    count(*) FILTER (WHERE state = 'idle') AS idle,
    count(*) FILTER (WHERE state = 'idle in transaction') AS idle_in_txn,
    count(*) FILTER (WHERE state = 'idle in transaction (aborted)') AS idle_in_txn_aborted,
    count(*) FILTER (WHERE wait_event_type IS NOT NULL) AS waiting,
    (SELECT setting::int FROM pg_settings WHERE name = 'max_connections') AS max_connections,
    ROUND(100.0 * count(*) / (SELECT setting::int FROM pg_settings WHERE name = 'max_connections'), 2) AS usage_pct
FROM pg_stat_activity
WHERE datname = current_database();

-- 1.4 Transaction ID age (wraparound risk)
\echo '-- 1.4 Transaction ID age (wraparound risk)'
SELECT 
    datname,
    age(datfrozenxid) AS xid_age,
    ROUND(100.0 * age(datfrozenxid) / 2147483647, 2) AS pct_to_wraparound,
    2147483647 - age(datfrozenxid) AS xids_remaining,
    CASE 
        WHEN age(datfrozenxid) > 1500000000 THEN '🔴 CRITICAL - VACUUM FREEZE IMMEDIATELY!'
        WHEN age(datfrozenxid) > 1000000000 THEN '🟠 WARNING - Plan VACUUM FREEZE'
        WHEN age(datfrozenxid) > 500000000 THEN '🟡 MONITOR'
        ELSE '🟢 OK' 
    END AS status
FROM pg_database
WHERE datname = current_database();

-- 1.5 Database statistics
\echo '-- 1.5 Database activity statistics'
SELECT 
    datname,
    numbackends AS connections,
    xact_commit AS commits,
    xact_rollback AS rollbacks,
    CASE WHEN xact_commit + xact_rollback > 0 
         THEN ROUND(100.0 * xact_rollback / (xact_commit + xact_rollback), 2) 
         ELSE 0 END AS rollback_pct,
    blks_read,
    blks_hit,
    tup_returned,
    tup_fetched,
    tup_inserted,
    tup_updated,
    tup_deleted,
    conflicts,
    deadlocks,
    temp_files,
    pg_size_pretty(temp_bytes) AS temp_bytes,
    stats_reset
FROM pg_stat_database
WHERE datname = current_database();

-- ============================================================================
-- SECTION 2: Query Performance (pg_stat_statements)
-- ============================================================================

\echo ''
\echo '============================================================================'
\echo 'SECTION 2: Query Performance Analysis'
\echo '============================================================================'

-- 2.1 Top 15 by mean execution time
\echo '-- 2.1 Top 15 slowest queries (by mean time)'
SELECT 
    queryid,
    LEFT(query, 80) AS query_preview,
    calls,
    ROUND((mean_time / 1000)::numeric, 3) AS mean_sec,
    ROUND((total_time / 1000 / 60)::numeric, 2) AS total_min,
    rows,
    ROUND((100.0 * shared_blks_hit / NULLIF(shared_blks_hit + shared_blks_read, 0))::numeric, 2) AS cache_hit_pct
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
  AND query NOT LIKE '%pg_stat%'
  AND calls > 0
ORDER BY mean_time DESC
LIMIT 15;

-- 2.2 Top 15 by total execution time
\echo '-- 2.2 Top 15 queries by total time (cumulative impact)'
SELECT 
    queryid,
    LEFT(query, 80) AS query_preview,
    calls,
    ROUND((total_time / 1000 / 60)::numeric, 2) AS total_min,
    ROUND((mean_time / 1000)::numeric, 3) AS mean_sec,
    ROUND((100.0 * total_time / NULLIF(SUM(total_time) OVER (), 0))::numeric, 2) AS pct_total_time
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
  AND query NOT LIKE '%pg_stat%'
ORDER BY total_time DESC
LIMIT 15;

-- 2.3 Top 15 by number of calls
\echo '-- 2.3 Top 15 most frequently called queries'
SELECT 
    queryid,
    LEFT(query, 80) AS query_preview,
    calls,
    ROUND((mean_time)::numeric, 2) AS mean_ms,
    ROUND((total_time / 1000 / 60)::numeric, 2) AS total_min,
    rows,
    ROUND(rows::numeric / NULLIF(calls, 0), 2) AS avg_rows_per_call
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
  AND query NOT LIKE '%pg_stat%'
ORDER BY calls DESC
LIMIT 15;

-- 2.4 Queries using temp files
\echo '-- 2.4 Queries using temp files (memory pressure)'
SELECT 
    queryid,
    LEFT(query, 80) AS query_preview,
    calls,
    temp_blks_read,
    temp_blks_written,
    pg_size_pretty((temp_blks_written * 8192)::bigint) AS temp_written,
    ROUND((mean_time / 1000)::numeric, 3) AS mean_sec
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
  AND temp_blks_written > 0
ORDER BY temp_blks_written DESC
LIMIT 15;

-- 2.5 Queries with poor cache hit ratio
\echo '-- 2.5 Queries with poor cache hit ratio (<90%)'
SELECT 
    queryid,
    LEFT(query, 80) AS query_preview,
    calls,
    shared_blks_read,
    shared_blks_hit,
    ROUND((100.0 * shared_blks_hit / NULLIF(shared_blks_hit + shared_blks_read, 0))::numeric, 2) AS cache_hit_pct,
    ROUND((mean_time / 1000)::numeric, 3) AS mean_sec
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
  AND (shared_blks_hit + shared_blks_read) > 1000
  AND shared_blks_hit::float / NULLIF(shared_blks_hit + shared_blks_read, 0) < 0.90
ORDER BY shared_blks_read DESC
LIMIT 15;

-- 2.6 Queries with high variance (unstable performance)
\echo '-- 2.6 Queries with high variance (unstable performance)'
SELECT 
    queryid,
    LEFT(query, 80) AS query_preview,
    calls,
    ROUND(mean_time::numeric, 2) AS mean_ms,
    ROUND(stddev_time::numeric, 2) AS stddev_ms,
    ROUND((stddev_time / NULLIF(mean_time, 0))::numeric, 2) AS coeff_variation,
    ROUND(min_time::numeric, 2) AS min_ms,
    ROUND(max_time::numeric, 2) AS max_ms
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
  AND calls > 100
  AND mean_time > 10
  AND stddev_time / NULLIF(mean_time, 0) > 1
ORDER BY (stddev_time / NULLIF(mean_time, 0)) DESC
LIMIT 15;

-- 2.7 Write-heavy queries
\echo '-- 2.7 Write-heavy queries (shared blocks dirtied)'
SELECT 
    queryid,
    LEFT(query, 80) AS query_preview,
    calls,
    shared_blks_dirtied,
    shared_blks_written,
    pg_size_pretty((shared_blks_dirtied * 8192)::bigint) AS data_dirtied,
    ROUND((mean_time / 1000)::numeric, 3) AS mean_sec
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
  AND shared_blks_dirtied > 1000
ORDER BY shared_blks_dirtied DESC
LIMIT 15;

-- ============================================================================
-- SECTION 3: Index Analysis
-- ============================================================================

\echo ''
\echo '============================================================================'
\echo 'SECTION 3: Index Analysis'
\echo '============================================================================'

-- 3.1 Index usage overview
\echo '-- 3.1 Index usage overview'
SELECT 
    'Total Indexes' AS metric,
    count(*)::text AS value
FROM pg_stat_user_indexes
UNION ALL
SELECT 'Unused Indexes (0 scans)', count(*)::text
FROM pg_stat_user_indexes WHERE idx_scan = 0
UNION ALL
SELECT 'Rarely Used (<100 scans)', count(*)::text
FROM pg_stat_user_indexes WHERE idx_scan > 0 AND idx_scan < 100
UNION ALL
SELECT 'Total Index Size', pg_size_pretty(sum(pg_relation_size(indexrelid)))
FROM pg_stat_user_indexes
UNION ALL
SELECT 'Unused Index Size', pg_size_pretty(sum(pg_relation_size(indexrelid)))
FROM pg_stat_user_indexes WHERE idx_scan = 0;

-- 3.2 Zero-efficiency indexes
\echo '-- 3.2 Zero-efficiency indexes (reads but no fetches)'
SELECT 
    schemaname,
    relname AS table_name,
    indexrelname AS index_name,
    idx_scan AS scans,
    idx_tup_read AS tuples_read,
    idx_tup_fetch AS tuples_fetched,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    'Index scans data but never returns useful rows' AS issue
FROM pg_stat_user_indexes
WHERE idx_tup_read > 10000
  AND idx_tup_fetch = 0
ORDER BY idx_tup_read DESC
LIMIT 20;

-- 3.3 Low-efficiency indexes
\echo '-- 3.3 Low-efficiency indexes (< 10% fetch ratio)'
SELECT 
    schemaname,
    relname AS table_name,
    indexrelname AS index_name,
    idx_scan AS scans,
    idx_tup_read AS tuples_read,
    idx_tup_fetch AS tuples_fetched,
    ROUND(100.0 * idx_tup_fetch / idx_tup_read, 2) AS efficiency_pct,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
FROM pg_stat_user_indexes
WHERE idx_tup_read > 100000
  AND idx_tup_fetch::float / NULLIF(idx_tup_read, 0) < 0.10
  AND idx_tup_fetch > 0
ORDER BY idx_tup_read DESC
LIMIT 20;

-- 3.4 Unused indexes (candidates for removal)
\echo '-- 3.4 Unused indexes (0 scans, > 1 MB) - DROP candidates'
SELECT 
    ui.schemaname,
    ui.relname AS table_name,
    ui.indexrelname AS index_name,
    ui.idx_scan,
    pg_size_pretty(pg_relation_size(ui.indexrelid)) AS index_size,
    pg_relation_size(ui.indexrelid) AS size_bytes,
    CASE 
        WHEN i.indisprimary THEN '🔴 PRIMARY KEY - DO NOT DROP'
        WHEN i.indisunique THEN '🟠 UNIQUE - verify constraints before drop'
        ELSE '🟢 Safe to DROP'
    END AS recommendation
FROM pg_stat_user_indexes ui
JOIN pg_index i ON ui.indexrelid = i.indexrelid
WHERE ui.idx_scan = 0
  AND pg_relation_size(ui.indexrelid) > 1 * 1024 * 1024
ORDER BY pg_relation_size(ui.indexrelid) DESC
LIMIT 30;

-- 3.5 Duplicate/Covered indexes
\echo '-- 3.5 Duplicate/Covered indexes (wasted space)'
WITH index_cols AS (
    SELECT 
        i.indexrelid,
        i.indrelid,
        i.indisprimary,
        i.indisunique,
        n.nspname AS schema_name,
        t.relname AS table_name,
        idx.relname AS index_name,
        array_agg(a.attname ORDER BY array_position(i.indkey, a.attnum)) AS columns,
        pg_relation_size(i.indexrelid) AS index_size
    FROM pg_index i
    JOIN pg_class idx ON idx.oid = i.indexrelid
    JOIN pg_class t ON t.oid = i.indrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY(i.indkey)
    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
    GROUP BY i.indexrelid, i.indrelid, i.indisprimary, i.indisunique, n.nspname, t.relname, idx.relname
)
SELECT 
    a.schema_name,
    a.table_name,
    a.index_name AS redundant_index,
    b.index_name AS covered_by_index,
    a.columns AS redundant_columns,
    b.columns AS covering_columns,
    pg_size_pretty(a.index_size) AS redundant_size,
    CASE 
        WHEN a.indisprimary THEN '🔴 PRIMARY KEY'
        WHEN a.indisunique THEN '🟠 UNIQUE'
        ELSE '🟢 Can DROP: ' || a.index_name
    END AS action
FROM index_cols a
JOIN index_cols b ON a.indrelid = b.indrelid 
    AND a.indexrelid != b.indexrelid
    AND a.columns <@ b.columns
    AND array_length(a.columns, 1) < array_length(b.columns, 1)
ORDER BY a.index_size DESC
LIMIT 20;

-- 3.6 Missing indexes (tables with excessive seq scans)
\echo '-- 3.6 Missing indexes (high seq scans on large tables)'
SELECT 
    schemaname,
    relname AS table_name,
    seq_scan,
    seq_tup_read,
    CASE WHEN seq_scan > 0 THEN seq_tup_read / seq_scan ELSE 0 END AS avg_rows_per_scan,
    idx_scan,
    ROUND(100.0 * idx_scan / NULLIF(seq_scan + idx_scan, 0), 2) AS idx_usage_pct,
    n_live_tup AS rows,
    pg_size_pretty(pg_total_relation_size(relid)) AS table_size
FROM pg_stat_user_tables
WHERE seq_scan > 50
  AND n_live_tup > 10000
  AND seq_tup_read / NULLIF(seq_scan, 0) > 1000
  AND (idx_scan IS NULL OR idx_scan < seq_scan)
ORDER BY seq_tup_read DESC
LIMIT 20;

-- 3.7 Index bloat candidates (large indexes with few scans)
\echo '-- 3.7 Index bloat candidates (large but rarely used)'
SELECT 
    schemaname,
    relname AS table_name,
    indexrelname AS index_name,
    idx_scan,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    pg_size_pretty(pg_relation_size(relid)) AS table_size,
    ROUND(100.0 * pg_relation_size(indexrelid) / NULLIF(pg_relation_size(relid), 0), 2) AS idx_to_table_pct,
    'Consider REINDEX if bloated' AS note
FROM pg_stat_user_indexes
WHERE pg_relation_size(indexrelid) > 100 * 1024 * 1024
  AND idx_scan < 1000
ORDER BY pg_relation_size(indexrelid) DESC
LIMIT 20;

-- ============================================================================
-- SECTION 4: Table Health & Maintenance
-- ============================================================================

\echo ''
\echo '============================================================================'
\echo 'SECTION 4: Table Health & Maintenance'
\echo '============================================================================'

-- 4.1 Tables overview
\echo '-- 4.1 Tables overview'
SELECT 
    'Total Tables' AS metric,
    count(*)::text AS value
FROM pg_stat_user_tables
UNION ALL
SELECT 'Total Table Size', pg_size_pretty(sum(pg_total_relation_size(relid)))
FROM pg_stat_user_tables
UNION ALL
SELECT 'Tables > 1GB', count(*)::text
FROM pg_stat_user_tables WHERE pg_total_relation_size(relid) > 1024*1024*1024
UNION ALL
SELECT 'Tables needing VACUUM', count(*)::text
FROM pg_stat_user_tables WHERE n_dead_tup > n_live_tup * 0.1 AND n_live_tup > 1000
UNION ALL
SELECT 'Tables never analyzed', count(*)::text
FROM pg_stat_user_tables WHERE last_analyze IS NULL AND last_autoanalyze IS NULL;

-- 4.2 Largest tables
\echo '-- 4.2 Largest tables'
SELECT 
    schemaname,
    relname AS table_name,
    pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
    pg_size_pretty(pg_relation_size(relid)) AS table_size,
    pg_size_pretty(pg_indexes_size(relid)) AS indexes_size,
    pg_size_pretty(pg_total_relation_size(relid) - pg_relation_size(relid) - pg_indexes_size(relid)) AS toast_size,
    n_live_tup AS rows,
    CASE WHEN n_live_tup > 0 
         THEN pg_relation_size(relid) / n_live_tup 
         ELSE 0 END AS bytes_per_row
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(relid) DESC
LIMIT 30;

-- 4.3 Tables with bloat (high dead tuple ratio)
\echo '-- 4.3 Tables with bloat (high dead tuple ratio)'
SELECT 
    schemaname,
    relname AS table_name,
    n_live_tup AS live_rows,
    n_dead_tup AS dead_rows,
    ROUND(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS dead_pct,
    pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
    last_vacuum,
    last_autovacuum,
    CASE 
        WHEN n_dead_tup > n_live_tup THEN '🔴 VACUUM FULL recommended'
        WHEN n_dead_tup > n_live_tup * 0.5 THEN '🟠 VACUUM ANALYZE urgently'
        WHEN n_dead_tup > n_live_tup * 0.2 THEN '🟡 VACUUM ANALYZE recommended'
        ELSE '🟢 Monitor'
    END AS recommendation
FROM pg_stat_user_tables
WHERE n_dead_tup > 10000 OR n_dead_tup > n_live_tup * 0.1
ORDER BY n_dead_tup DESC
LIMIT 20;

-- 4.4 Tables approaching autovacuum threshold
\echo '-- 4.4 Tables approaching autovacuum threshold'
SELECT 
    schemaname,
    relname AS table_name,
    n_live_tup,
    n_dead_tup,
    -- Default autovacuum threshold: 50 + 0.2 * n_live_tup
    50 + ROUND(0.2 * n_live_tup) AS vacuum_threshold,
    ROUND(100.0 * n_dead_tup / NULLIF(50 + 0.2 * n_live_tup, 0), 2) AS pct_to_threshold,
    last_autovacuum,
    pg_size_pretty(pg_total_relation_size(relid)) AS size
FROM pg_stat_user_tables
WHERE n_dead_tup > (50 + 0.2 * n_live_tup) * 0.8
  AND n_live_tup > 1000
ORDER BY n_dead_tup DESC
LIMIT 20;

-- 4.5 Tables never vacuumed/analyzed
\echo '-- 4.5 Tables never vacuumed/analyzed (> 10 MB)'
SELECT 
    schemaname,
    relname AS table_name,
    pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
    n_live_tup,
    n_dead_tup,
    n_tup_ins AS inserts,
    n_tup_upd AS updates,
    n_tup_del AS deletes,
    last_vacuum,
    last_autovacuum,
    last_analyze,
    last_autoanalyze,
    '🔴 Run ANALYZE' AS action
FROM pg_stat_user_tables
WHERE (last_vacuum IS NULL AND last_autovacuum IS NULL)
   OR (last_analyze IS NULL AND last_autoanalyze IS NULL)
ORDER BY pg_total_relation_size(relid) DESC
LIMIT 20;

-- 4.6 Tables with stale statistics
\echo '-- 4.6 Tables with stale statistics (analyze > 7 days ago)'
SELECT 
    schemaname,
    relname AS table_name,
    n_live_tup,
    n_mod_since_analyze AS modifications_since_analyze,
    ROUND(100.0 * n_mod_since_analyze / NULLIF(n_live_tup, 0), 2) AS mod_pct,
    last_analyze,
    last_autoanalyze,
    GREATEST(last_analyze, last_autoanalyze) AS last_any_analyze,
    pg_size_pretty(pg_total_relation_size(relid)) AS size
FROM pg_stat_user_tables
WHERE n_live_tup > 10000
  AND (
    (last_analyze IS NULL AND last_autoanalyze IS NULL)
    OR GREATEST(last_analyze, last_autoanalyze) < now() - INTERVAL '7 days'
    OR n_mod_since_analyze > n_live_tup * 0.1
  )
ORDER BY n_mod_since_analyze DESC
LIMIT 20;

-- 4.7 Tables with autovacuum disabled
\echo '-- 4.7 Tables with autovacuum disabled'
SELECT 
    n.nspname AS schema_name,
    c.relname AS table_name,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size,
    c.reloptions,
    '🔴 Enable autovacuum!' AS action
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND c.relkind = 'r'
  AND c.reloptions::text LIKE '%autovacuum_enabled=false%'
ORDER BY pg_total_relation_size(c.oid) DESC;

-- 4.8 Table I/O statistics
\echo '-- 4.8 Table I/O statistics (reads from disk)'
SELECT 
    schemaname,
    relname AS table_name,
    heap_blks_read AS blocks_read,
    heap_blks_hit AS blocks_hit,
    ROUND(100.0 * heap_blks_hit / NULLIF(heap_blks_hit + heap_blks_read, 0), 2) AS cache_hit_pct,
    pg_size_pretty((heap_blks_read * 8192)::bigint) AS data_from_disk,
    pg_size_pretty(pg_total_relation_size(relid)) AS total_size
FROM pg_statio_user_tables
WHERE heap_blks_read > 10000
ORDER BY heap_blks_read DESC
LIMIT 20;

-- 4.9 HOT updates ratio
\echo '-- 4.9 HOT updates ratio (index efficiency)'
SELECT 
    schemaname,
    relname AS table_name,
    n_tup_upd AS updates,
    n_tup_hot_upd AS hot_updates,
    ROUND(100.0 * n_tup_hot_upd / NULLIF(n_tup_upd, 0), 2) AS hot_update_pct,
    pg_size_pretty(pg_total_relation_size(relid)) AS size,
    CASE 
        WHEN n_tup_hot_upd::float / NULLIF(n_tup_upd, 0) < 0.5 
        THEN '🟠 Low HOT ratio - check fillfactor'
        ELSE '🟢 Good'
    END AS status
FROM pg_stat_user_tables
WHERE n_tup_upd > 10000
ORDER BY n_tup_upd DESC
LIMIT 20;

-- ============================================================================
-- SECTION 5: Connections, Sessions & Activity
-- ============================================================================

\echo ''
\echo '============================================================================'
\echo 'SECTION 5: Connections, Sessions & Activity'
\echo '============================================================================'

-- 5.1 Connections by state
\echo '-- 5.1 Connections by state'
SELECT 
    state,
    count(*) AS connections,
    ROUND(100.0 * count(*) / SUM(count(*)) OVER (), 2) AS pct
FROM pg_stat_activity
WHERE datname = current_database()
GROUP BY state
ORDER BY connections DESC;

-- 5.2 Connections by user
\echo '-- 5.2 Connections by user'
SELECT 
    usename,
    count(*) AS connections,
    count(*) FILTER (WHERE state = 'active') AS active,
    count(*) FILTER (WHERE state = 'idle') AS idle,
    count(*) FILTER (WHERE state LIKE '%transaction%') AS in_transaction,
    MAX(EXTRACT(EPOCH FROM (now() - backend_start)))::int AS oldest_conn_sec
FROM pg_stat_activity
WHERE datname = current_database()
GROUP BY usename
ORDER BY connections DESC;

-- 5.3 Connections by application
\echo '-- 5.3 Connections by application'
SELECT 
    COALESCE(application_name, 'unknown') AS application,
    count(*) AS connections,
    count(*) FILTER (WHERE state = 'active') AS active,
    count(*) FILTER (WHERE state = 'idle') AS idle
FROM pg_stat_activity
WHERE datname = current_database()
GROUP BY application_name
ORDER BY connections DESC
LIMIT 15;

-- 5.4 Long running queries
\echo '-- 5.4 Long running queries (> 1 min)'
SELECT 
    pid,
    usename,
    application_name,
    state,
    EXTRACT(EPOCH FROM (now() - query_start))::int AS duration_sec,
    wait_event_type,
    wait_event,
    LEFT(query, 100) AS query
FROM pg_stat_activity
WHERE state = 'active'
  AND query_start < now() - INTERVAL '1 minute'
  AND pid != pg_backend_pid()
ORDER BY query_start;

-- 5.5 Idle in transaction
\echo '-- 5.5 Idle in transaction connections'
SELECT 
    pid,
    usename,
    application_name,
    state,
    EXTRACT(EPOCH FROM (now() - state_change))::int AS idle_in_txn_sec,
    EXTRACT(EPOCH FROM (now() - xact_start))::int AS txn_duration_sec,
    LEFT(query, 100) AS last_query
FROM pg_stat_activity
WHERE state LIKE '%transaction%'
ORDER BY xact_start;

-- 5.6 Oldest connections
\echo '-- 5.6 Oldest connections'
SELECT 
    pid,
    usename,
    application_name,
    client_addr,
    backend_start,
    EXTRACT(EPOCH FROM (now() - backend_start))::int / 3600 AS conn_hours,
    state
FROM pg_stat_activity
WHERE datname = current_database()
ORDER BY backend_start
LIMIT 15;

-- 5.7 Wait events summary
\echo '-- 5.7 Wait events summary'
SELECT 
    wait_event_type,
    wait_event,
    count(*) AS sessions
FROM pg_stat_activity
WHERE wait_event IS NOT NULL
  AND datname = current_database()
GROUP BY wait_event_type, wait_event
ORDER BY sessions DESC
LIMIT 15;

-- ============================================================================
-- SECTION 6: Locks & Blocking
-- ============================================================================

\echo ''
\echo '============================================================================'
\echo 'SECTION 6: Locks & Blocking'
\echo '============================================================================'

-- 6.1 Lock types summary
\echo '-- 6.1 Lock types summary'
SELECT 
    locktype,
    mode,
    count(*) AS locks,
    count(*) FILTER (WHERE granted) AS granted,
    count(*) FILTER (WHERE NOT granted) AS waiting
FROM pg_locks
GROUP BY locktype, mode
ORDER BY locks DESC;

-- 6.2 Current blocking chains
\echo '-- 6.2 Current blocking chains'
SELECT 
    blocked.pid AS blocked_pid,
    blocked.usename AS blocked_user,
    blocked.application_name AS blocked_app,
    blocking.pid AS blocking_pid,
    blocking.usename AS blocking_user,
    blocking.application_name AS blocking_app,
    EXTRACT(EPOCH FROM (now() - blocked.query_start))::int AS blocked_duration_sec,
    blocked_locks.locktype,
    blocked_locks.mode AS blocked_mode,
    LEFT(blocked.query, 60) AS blocked_query,
    LEFT(blocking.query, 60) AS blocking_query
FROM pg_stat_activity blocked
JOIN pg_locks blocked_locks ON blocked.pid = blocked_locks.pid AND NOT blocked_locks.granted
JOIN pg_locks blocking_locks ON blocked_locks.locktype = blocking_locks.locktype
    AND blocked_locks.database IS NOT DISTINCT FROM blocking_locks.database
    AND blocked_locks.relation IS NOT DISTINCT FROM blocking_locks.relation
    AND blocked_locks.page IS NOT DISTINCT FROM blocking_locks.page
    AND blocked_locks.tuple IS NOT DISTINCT FROM blocking_locks.tuple
    AND blocked_locks.virtualxid IS NOT DISTINCT FROM blocking_locks.virtualxid
    AND blocked_locks.transactionid IS NOT DISTINCT FROM blocking_locks.transactionid
    AND blocked_locks.classid IS NOT DISTINCT FROM blocking_locks.classid
    AND blocked_locks.objid IS NOT DISTINCT FROM blocking_locks.objid
    AND blocked_locks.objsubid IS NOT DISTINCT FROM blocking_locks.objsubid
    AND blocked_locks.pid != blocking_locks.pid
    AND blocking_locks.granted
JOIN pg_stat_activity blocking ON blocking_locks.pid = blocking.pid
ORDER BY blocked.query_start;

-- 6.3 Tables with most locks
\echo '-- 6.3 Tables with most locks'
SELECT 
    c.relname AS table_name,
    l.locktype,
    l.mode,
    count(*) AS lock_count,
    count(*) FILTER (WHERE NOT l.granted) AS waiting
FROM pg_locks l
JOIN pg_class c ON l.relation = c.oid
WHERE c.relkind = 'r'
GROUP BY c.relname, l.locktype, l.mode
HAVING count(*) > 1
ORDER BY lock_count DESC
LIMIT 20;

-- ============================================================================
-- SECTION 7: Replication & WAL
-- ============================================================================

\echo ''
\echo '============================================================================'
\echo 'SECTION 7: Replication & WAL'
\echo '============================================================================'

-- 7.1 Replication slots
\echo '-- 7.1 Replication slots'
SELECT 
    slot_name,
    slot_type,
    database,
    active,
    xmin,
    catalog_xmin,
    restart_lsn,
    confirmed_flush_lsn,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS lag_size,
    CASE 
        WHEN NOT active THEN '🔴 INACTIVE - may block WAL recycling'
        WHEN pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) > 1073741824 THEN '🟠 Large lag (>1GB)'
        ELSE '🟢 OK'
    END AS status
FROM pg_replication_slots;

-- 7.2 Replication status
\echo '-- 7.2 Replication status'
SELECT 
    client_addr,
    usename,
    application_name,
    state,
    sync_state,
    pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS replay_lag,
    pg_size_pretty(pg_wal_lsn_diff(sent_lsn, flush_lsn)) AS flush_lag,
    pg_size_pretty(pg_wal_lsn_diff(sent_lsn, write_lsn)) AS write_lag
FROM pg_stat_replication;

-- 7.3 WAL statistics
\echo '-- 7.3 WAL statistics'
SELECT 
    pg_current_wal_lsn() AS current_wal_lsn;

-- 7.4 Archive status
\echo '-- 7.4 Archive status'
SELECT 
    archived_count,
    last_archived_wal,
    last_archived_time,
    failed_count,
    last_failed_wal,
    last_failed_time,
    CASE 
        WHEN failed_count > 0 THEN '🔴 Archive failures detected'
        ELSE '🟢 OK'
    END AS status
FROM pg_stat_archiver;

-- ============================================================================
-- SECTION 8: Background Processes
-- ============================================================================

\echo ''
\echo '============================================================================'
\echo 'SECTION 8: Background Processes'
\echo '============================================================================'

-- 8.1 Background writer stats
\echo '-- 8.1 Background writer stats'
SELECT 
    checkpoints_timed,
    checkpoints_req,
    ROUND(100.0 * checkpoints_req / NULLIF(checkpoints_timed + checkpoints_req, 0), 2) AS pct_requested,
    checkpoint_write_time / 1000 AS checkpoint_write_sec,
    checkpoint_sync_time / 1000 AS checkpoint_sync_sec,
    buffers_checkpoint,
    buffers_clean,
    maxwritten_clean,
    buffers_backend,
    buffers_backend_fsync,
    buffers_alloc,
    stats_reset,
    CASE 
        WHEN checkpoints_req::float / NULLIF(checkpoints_timed + checkpoints_req, 0) > 0.5 
        THEN '🟠 Too many forced checkpoints - increase checkpoint_segments'
        ELSE '🟢 OK'
    END AS status
FROM pg_stat_bgwriter;

-- 8.2 Autovacuum workers
\echo '-- 8.2 Current autovacuum workers'
SELECT 
    pid,
    datname,
    usename,
    EXTRACT(EPOCH FROM (now() - query_start))::int AS duration_sec,
    state,
    LEFT(query, 100) AS query
FROM pg_stat_activity
WHERE query LIKE 'autovacuum:%'
ORDER BY query_start;

-- 8.3 Vacuum progress
\echo '-- 8.3 Vacuum progress'
SELECT 
    pid,
    datname,
    relid::regclass AS table_name,
    phase,
    heap_blks_total,
    heap_blks_scanned,
    ROUND(100.0 * heap_blks_scanned / NULLIF(heap_blks_total, 0), 2) AS scan_pct,
    heap_blks_vacuumed,
    index_vacuum_count,
    max_dead_tuples,
    num_dead_tuples
FROM pg_stat_progress_vacuum;

-- ============================================================================
-- SECTION 9: Configuration Analysis
-- ============================================================================

\echo ''
\echo '============================================================================'
\echo 'SECTION 9: Configuration Analysis'
\echo '============================================================================'

-- 9.1 Memory settings
\echo '-- 9.1 Memory settings'
SELECT 
    name,
    setting,
    unit,
    CASE name
        WHEN 'shared_buffers' THEN 'Target: ~25% of RAM. Current: ' || pg_size_pretty(setting::bigint * 
            CASE unit WHEN '8kB' THEN 8192 WHEN 'kB' THEN 1024 WHEN 'MB' THEN 1048576 ELSE 1 END)
        WHEN 'effective_cache_size' THEN 'Target: ~75% of RAM. Current: ' || pg_size_pretty(setting::bigint * 
            CASE unit WHEN '8kB' THEN 8192 WHEN 'kB' THEN 1024 WHEN 'MB' THEN 1048576 ELSE 1 END)
        WHEN 'work_mem' THEN 'Per-sort/hash. Be careful with high values + many connections'
        WHEN 'maintenance_work_mem' THEN 'For VACUUM, CREATE INDEX. Can be higher.'
        WHEN 'wal_buffers' THEN 'Usually auto-tuned. -1 = auto'
        ELSE ''
    END AS recommendation
FROM pg_settings
WHERE name IN ('shared_buffers', 'effective_cache_size', 'work_mem', 
               'maintenance_work_mem', 'wal_buffers', 'huge_pages')
ORDER BY name;

-- 9.2 Connection settings
\echo '-- 9.2 Connection settings'
SELECT 
    name,
    setting,
    unit,
    CASE name
        WHEN 'max_connections' THEN 'Current connections: ' || (SELECT count(*) FROM pg_stat_activity)::text
        WHEN 'superuser_reserved_connections' THEN 'Reserved for superusers'
        ELSE ''
    END AS note
FROM pg_settings
WHERE name IN ('max_connections', 'superuser_reserved_connections', 
               'tcp_keepalives_idle', 'tcp_keepalives_interval', 'tcp_keepalives_count')
ORDER BY name;

-- 9.3 Checkpoint & WAL settings
\echo '-- 9.3 Checkpoint & WAL settings'
SELECT 
    name,
    setting,
    unit,
    CASE name
        WHEN 'checkpoint_completion_target' THEN 'Target: 0.9'
        WHEN 'checkpoint_timeout' THEN 'Default: 5min. Consider 15-30min for write-heavy'
        WHEN 'max_wal_size' THEN 'Increase if frequent checkpoints'
        ELSE ''
    END AS recommendation
FROM pg_settings
WHERE name IN ('checkpoint_completion_target', 'checkpoint_timeout', 
               'max_wal_size', 'min_wal_size', 'wal_level', 'archive_mode')
ORDER BY name;

-- 9.4 Autovacuum settings
\echo '-- 9.4 Autovacuum settings'
SELECT 
    name,
    setting,
    unit,
    CASE name
        WHEN 'autovacuum' THEN CASE setting WHEN 'on' THEN '🟢 Enabled' ELSE '🔴 DISABLED!' END
        WHEN 'autovacuum_max_workers' THEN 'Consider increasing for many tables'
        WHEN 'autovacuum_vacuum_scale_factor' THEN 'Default 0.2 = vacuum when 20% dead rows'
        WHEN 'autovacuum_analyze_scale_factor' THEN 'Default 0.1 = analyze when 10% changed'
        ELSE ''
    END AS note
FROM pg_settings
WHERE name LIKE 'autovacuum%'
ORDER BY name;

-- 9.5 Query planner settings
\echo '-- 9.5 Query planner settings'
SELECT 
    name,
    setting,
    unit,
    CASE name
        WHEN 'random_page_cost' THEN 'For SSD: use 1.1-1.5. Current may be too high for SSD.'
        WHEN 'effective_io_concurrency' THEN 'For SSD: use 200'
        WHEN 'seq_page_cost' THEN 'Usually keep at 1.0'
        ELSE ''
    END AS recommendation
FROM pg_settings
WHERE name IN ('random_page_cost', 'seq_page_cost', 'effective_io_concurrency',
               'cpu_tuple_cost', 'cpu_index_tuple_cost', 'cpu_operator_cost',
               'parallel_tuple_cost', 'parallel_setup_cost')
ORDER BY name;

-- 9.6 Parallelism settings
\echo '-- 9.6 Parallelism settings'
SELECT 
    name,
    setting,
    unit
FROM pg_settings
WHERE name IN ('max_worker_processes', 'max_parallel_workers', 
               'max_parallel_workers_per_gather', 'max_parallel_maintenance_workers',
               'parallel_leader_participation', 'min_parallel_table_scan_size',
               'min_parallel_index_scan_size')
ORDER BY name;

-- 9.7 Logging settings
\echo '-- 9.7 Logging settings'
SELECT 
    name,
    setting,
    unit
FROM pg_settings
WHERE name IN ('log_min_duration_statement', 'log_statement', 'log_lock_waits',
               'log_temp_files', 'log_checkpoints', 'log_connections',
               'log_disconnections', 'log_autovacuum_min_duration')
ORDER BY name;

-- ============================================================================
-- SECTION 10: Extensions
-- ============================================================================

\echo ''
\echo '============================================================================'
\echo 'SECTION 10: Installed Extensions'
\echo '============================================================================'

\echo '-- 10.1 Installed extensions'
SELECT 
    extname AS extension,
    extversion AS version,
    n.nspname AS schema
FROM pg_extension e
JOIN pg_namespace n ON e.extnamespace = n.oid
ORDER BY extname;

-- ============================================================================
-- SECTION 11: Security Overview
-- ============================================================================

\echo ''
\echo '============================================================================'
\echo 'SECTION 11: Security Overview'
\echo '============================================================================'

-- 11.1 Superusers
\echo '-- 11.1 Superusers'
SELECT 
    rolname,
    rolsuper,
    rolinherit,
    rolcreaterole,
    rolcreatedb,
    rolcanlogin,
    rolreplication,
    rolbypassrls
FROM pg_roles
WHERE rolsuper = true
ORDER BY rolname;

-- 11.2 Users with login
\echo '-- 11.2 Users with login capability'
SELECT 
    rolname,
    rolsuper,
    rolcreatedb,
    rolcreaterole,
    rolreplication,
    rolconnlimit,
    rolvaliduntil
FROM pg_roles
WHERE rolcanlogin = true
ORDER BY rolname;

-- 11.3 Tables with RLS disabled
\echo '-- 11.3 Row Level Security status'
SELECT 
    schemaname,
    tablename,
    rowsecurity
FROM pg_tables
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY schemaname, tablename
LIMIT 20;

-- ============================================================================
-- SECTION 12: Health Check Summary
-- ============================================================================

\echo ''
\echo '╔══════════════════════════════════════════════════════════════════════════╗'
\echo '║                         HEALTH CHECK SUMMARY                              ║'
\echo '╚══════════════════════════════════════════════════════════════════════════╝'
\echo ''

SELECT '📊 Database' AS category, 'Size' AS metric, pg_size_pretty(pg_database_size(current_database())) AS value
UNION ALL SELECT '📊 Database', 'Tables', (SELECT count(*)::text FROM pg_stat_user_tables)
UNION ALL SELECT '📊 Database', 'Indexes', (SELECT count(*)::text FROM pg_stat_user_indexes)
UNION ALL SELECT '📊 Database', 'Uptime', (SELECT EXTRACT(EPOCH FROM (now() - pg_postmaster_start_time()))::int / 86400 || ' days')

UNION ALL SELECT '🔗 Connections', 'Total', (SELECT count(*)::text FROM pg_stat_activity WHERE datname = current_database())
UNION ALL SELECT '🔗 Connections', 'Active', (SELECT count(*)::text FROM pg_stat_activity WHERE state = 'active' AND pid != pg_backend_pid())
UNION ALL SELECT '🔗 Connections', 'Idle in Transaction', (SELECT count(*)::text FROM pg_stat_activity WHERE state LIKE '%transaction%')
UNION ALL SELECT '🔗 Connections', 'Long Running (>5min)', (SELECT count(*)::text FROM pg_stat_activity WHERE state = 'active' AND query_start < now() - INTERVAL '5 minutes')

UNION ALL SELECT '🔒 Locks', 'Blocked Sessions', (SELECT count(*)::text FROM pg_locks WHERE NOT granted)

UNION ALL SELECT '💾 Cache', 'Table Hit Ratio', (SELECT ROUND(100.0 * sum(heap_blks_hit) / nullif(sum(heap_blks_hit) + sum(heap_blks_read), 0), 2)::text || '%' FROM pg_statio_user_tables)
UNION ALL SELECT '💾 Cache', 'Index Hit Ratio', (SELECT ROUND(100.0 * sum(idx_blks_hit) / nullif(sum(idx_blks_hit) + sum(idx_blks_read), 0), 2)::text || '%' FROM pg_statio_user_indexes)

UNION ALL SELECT '🧹 Maintenance', 'Tables Needing VACUUM', (SELECT count(*)::text FROM pg_stat_user_tables WHERE n_dead_tup > n_live_tup * 0.1 AND n_live_tup > 1000)
UNION ALL SELECT '🧹 Maintenance', 'Tables Never Analyzed', (SELECT count(*)::text FROM pg_stat_user_tables WHERE last_analyze IS NULL AND last_autoanalyze IS NULL AND n_live_tup > 1000)

UNION ALL SELECT '📇 Indexes', 'Unused (>1MB)', (SELECT count(*)::text FROM pg_stat_user_indexes ui JOIN pg_index i ON ui.indexrelid = i.indexrelid WHERE idx_scan = 0 AND pg_relation_size(ui.indexrelid) > 1024*1024 AND NOT i.indisprimary AND NOT i.indisunique)
UNION ALL SELECT '📇 Indexes', 'Zero Efficiency', (SELECT count(*)::text FROM pg_stat_user_indexes WHERE idx_tup_read > 10000 AND idx_tup_fetch = 0)

UNION ALL SELECT '⚠️ XID Age', 'Status', (SELECT CASE WHEN age(datfrozenxid) > 1500000000 THEN '🔴 CRITICAL' WHEN age(datfrozenxid) > 1000000000 THEN '🟠 WARNING' ELSE '🟢 OK (' || age(datfrozenxid)::text || ')' END FROM pg_database WHERE datname = current_database());

\echo ''
\echo '============================================================================'
\echo 'ISSUE COUNTS'
\echo '============================================================================'

SELECT '🔴 Critical' AS severity, 'Tables with autovacuum disabled' AS issue, 
    (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace 
     WHERE c.relkind = 'r' AND c.reloptions::text LIKE '%autovacuum_enabled=false%')::text AS count
UNION ALL
SELECT '🔴 Critical', 'Inactive replication slots',
    (SELECT count(*) FROM pg_replication_slots WHERE NOT active)::text
UNION ALL
SELECT '🟠 Warning', 'Zero-efficiency indexes',
    (SELECT count(*) FROM pg_stat_user_indexes WHERE idx_tup_read > 10000 AND idx_tup_fetch = 0)::text
UNION ALL
SELECT '🟠 Warning', 'Low-efficiency indexes (<10%)',
    (SELECT count(*) FROM pg_stat_user_indexes WHERE idx_tup_read > 100000 AND idx_tup_fetch::float / NULLIF(idx_tup_read, 0) < 0.10)::text
UNION ALL
SELECT '🟠 Warning', 'Unused indexes (>1MB)',
    (SELECT count(*) FROM pg_stat_user_indexes ui JOIN pg_index i ON ui.indexrelid = i.indexrelid 
     WHERE idx_scan = 0 AND pg_relation_size(ui.indexrelid) > 1024*1024 AND NOT i.indisprimary AND NOT i.indisunique)::text
UNION ALL
SELECT '🟠 Warning', 'Tables needing VACUUM (>10% dead)',
    (SELECT count(*) FROM pg_stat_user_tables WHERE n_dead_tup > n_live_tup * 0.1 AND n_live_tup > 1000)::text
UNION ALL
SELECT '🟠 Warning', 'Tables with bloat (>20% dead)',
    (SELECT count(*) FROM pg_stat_user_tables WHERE n_dead_tup > n_live_tup * 0.2 AND n_live_tup > 1000)::text
UNION ALL
SELECT '🟡 Info', 'Tables never analyzed',
    (SELECT count(*) FROM pg_stat_user_tables WHERE last_analyze IS NULL AND last_autoanalyze IS NULL AND n_live_tup > 1000)::text
UNION ALL
SELECT '🟡 Info', 'Queries using temp files',
    (SELECT count(*) FROM pg_stat_statements WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database()) AND temp_blks_written > 0)::text;

\echo ''
\echo '╔══════════════════════════════════════════════════════════════════════════╗'
\echo '║                     END OF COMPREHENSIVE REPORT                           ║'
\echo '╚══════════════════════════════════════════════════════════════════════════╝'
