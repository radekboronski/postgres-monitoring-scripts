\set ECHO queries

-- Set schema search path (change 'test' to your schema if different)
SET search_path TO test, public;

\echo ''
\echo '============================================================================'
\echo 'PostgreSQL Diagnostic Queries - Data Ingestion Pipeline'
\echo '============================================================================'
\echo 'Purpose: Identify concurrency issues, locks, missing indexes, bottlenecks'
\echo 'Usage: Run during peak load for best results'
\echo '============================================================================'
\echo ''

\echo '============================================================================'
\echo 'PART 1: ACTIVE SESSIONS AND LOCKS (RUN DURING PEAK LOAD)'
\echo '============================================================================'
\echo ''

\echo '----------------------------------------------------------------------------'
\echo '1.1. Active queries and their state'
\echo '----------------------------------------------------------------------------'

SELECT 
    pid,
    usename,
    application_name,
    client_addr,
    state,
    wait_event_type,
    wait_event,
    query_start,
    NOW() - query_start AS duration,
    LEFT(query, 100) AS query_preview
FROM pg_stat_activity
WHERE state != 'idle'
  AND pid != pg_backend_pid()
ORDER BY query_start;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '1.2. Queries waiting for locks'
\echo '----------------------------------------------------------------------------'

SELECT 
    blocked.pid AS blocked_pid,
    blocked.usename AS blocked_user,
    blocking.pid AS blocking_pid,
    blocking.usename AS blocking_user,
    LEFT(blocked.query, 80) AS blocked_query,
    LEFT(blocking.query, 80) AS blocking_query,
    blocked.wait_event_type,
    blocked.wait_event
FROM pg_stat_activity blocked
JOIN pg_stat_activity blocking 
    ON blocking.pid = ANY(pg_blocking_pids(blocked.pid))
WHERE blocked.wait_event_type = 'Lock';

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '1.3. Row-level lock details (not granted)'
\echo '----------------------------------------------------------------------------'

SELECT 
    l.locktype,
    l.relation::regclass AS table_name,
    l.mode,
    l.granted,
    l.pid,
    a.usename,
    a.query_start,
    NOW() - a.query_start AS lock_duration,
    LEFT(a.query, 80) AS query
FROM pg_locks l
JOIN pg_stat_activity a ON l.pid = a.pid
WHERE l.relation IS NOT NULL
  AND NOT l.granted
ORDER BY a.query_start;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '1.4. Deadlock detection'
\echo '----------------------------------------------------------------------------'

SELECT 
    pid,
    usename,
    pg_blocking_pids(pid) AS blocked_by,
    LEFT(query, 100) AS query
FROM pg_stat_activity
WHERE cardinality(pg_blocking_pids(pid)) > 0;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '1.5. Lock conflicts by table'
\echo '----------------------------------------------------------------------------'

SELECT 
    l.relation::regclass AS table_name,
    l.mode,
    COUNT(*) AS lock_count,
    COUNT(*) FILTER (WHERE NOT l.granted) AS waiting_count
FROM pg_locks l
WHERE l.relation IS NOT NULL
GROUP BY l.relation::regclass, l.mode
HAVING COUNT(*) > 1
ORDER BY waiting_count DESC, lock_count DESC;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '1.6. Wait events distribution'
\echo '----------------------------------------------------------------------------'

SELECT 
    wait_event_type,
    wait_event,
    COUNT(*) AS occurrence_count
FROM pg_stat_activity
WHERE wait_event IS NOT NULL
  AND state != 'idle'
GROUP BY wait_event_type, wait_event
ORDER BY occurrence_count DESC;

\echo ''
\echo '============================================================================'
\echo 'PART 2: INDEX ANALYSIS'
\echo '============================================================================'
\echo ''

\echo '----------------------------------------------------------------------------'
\echo '2.1. Missing indexes - tables with high sequential scan count'
\echo '----------------------------------------------------------------------------'

SELECT 
    schemaname,
    relname AS table_name,
    seq_scan,
    seq_tup_read,
    idx_scan,
    idx_tup_fetch,
    n_live_tup AS row_count,
    CASE WHEN seq_scan > 0 
         THEN ROUND((seq_tup_read::numeric / seq_scan), 2) 
         ELSE 0 
    END AS avg_rows_per_seq_scan
FROM pg_stat_user_tables
WHERE seq_scan > 100
  AND n_live_tup > 10000
  AND (idx_scan IS NULL OR idx_scan < seq_scan)
ORDER BY seq_tup_read DESC
LIMIT 20;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '2.2. Existing indexes on pipeline tables'
\echo '----------------------------------------------------------------------------'

SELECT 
    t.relname AS table_name,
    i.relname AS index_name,
    a.attname AS column_name,
    ix.indisunique AS is_unique,
    ix.indisprimary AS is_primary,
    pg_size_pretty(pg_relation_size(i.oid)) AS index_size
FROM pg_class t
JOIN pg_index ix ON t.oid = ix.indrelid
JOIN pg_class i ON i.oid = ix.indexrelid
JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY(ix.indkey)
WHERE t.relkind = 'r'
  AND t.relname IN ('entities', 'group_memberships', 'items', 
                    'entity_images', 'personal_details', 'phone_appdata',
                    'message_application_data', 'item_reactions',
                    'entity_relations', 'group_application_data')
ORDER BY t.relname, i.relname;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '2.3. Unused indexes (candidates for removal)'
\echo '----------------------------------------------------------------------------'

SELECT 
    schemaname,
    relname AS table_name,
    indexrelname AS index_name,
    idx_scan,
    idx_tup_read,
    idx_tup_fetch,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
FROM pg_stat_user_indexes
WHERE idx_scan < 50
  AND schemaname = 'public'
ORDER BY pg_relation_size(indexrelid) DESC
LIMIT 20;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '2.4. Index usage ratio per pipeline table'
\echo '----------------------------------------------------------------------------'

SELECT 
    relname AS table_name,
    seq_scan,
    idx_scan,
    CASE WHEN (seq_scan + idx_scan) > 0 
         THEN ROUND(100.0 * idx_scan / (seq_scan + idx_scan), 2)
         ELSE 0 
    END AS index_usage_pct,
    n_live_tup AS row_count
FROM pg_stat_user_tables
WHERE relname IN ('entities', 'group_memberships', 'items', 
                  'entity_images', 'personal_details', 'phone_appdata',
                  'message_application_data', 'item_reactions',
                  'entity_relations', 'group_application_data')
ORDER BY index_usage_pct ASC;

\echo ''
\echo '============================================================================'
\echo 'PART 3: TABLE STATISTICS AND BLOAT'
\echo '============================================================================'
\echo ''

\echo '----------------------------------------------------------------------------'
\echo '3.1. Table sizes and bloat for pipeline tables'
\echo '----------------------------------------------------------------------------'

SELECT 
    schemaname,
    relname AS table_name,
    n_live_tup AS live_rows,
    n_dead_tup AS dead_rows,
    CASE WHEN n_live_tup > 0 
         THEN ROUND(100.0 * n_dead_tup / (n_live_tup + n_dead_tup), 2) 
         ELSE 0 
    END AS dead_pct,
    last_vacuum,
    last_autovacuum,
    last_analyze,
    last_autoanalyze,
    pg_size_pretty(pg_total_relation_size(relid)) AS total_size
FROM pg_stat_user_tables
WHERE relname IN ('entities', 'group_memberships', 'items', 
                  'entity_images', 'personal_details', 'phone_appdata',
                  'message_application_data', 'item_reactions',
                  'entity_relations', 'group_application_data', 'countries')
ORDER BY n_dead_tup DESC;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '3.2. Tables needing VACUUM (dead tuples > 10000)'
\echo '----------------------------------------------------------------------------'

SELECT 
    relname,
    n_dead_tup,
    n_live_tup,
    ROUND(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS dead_pct,
    last_autovacuum,
    autovacuum_count,
    autoanalyze_count,
    pg_size_pretty(pg_total_relation_size(relid)) AS total_size
FROM pg_stat_user_tables
WHERE n_dead_tup > 10000
ORDER BY n_dead_tup DESC;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '3.3. Table modification statistics'
\echo '----------------------------------------------------------------------------'

SELECT 
    relname AS table_name,
    n_tup_ins AS inserts,
    n_tup_upd AS updates,
    n_tup_del AS deletes,
    n_tup_hot_upd AS hot_updates,
    CASE WHEN n_tup_upd > 0 
         THEN ROUND(100.0 * n_tup_hot_upd / n_tup_upd, 2) 
         ELSE 0 
    END AS hot_update_pct
FROM pg_stat_user_tables
WHERE relname IN ('entities', 'group_memberships', 'items',
                  'entity_images', 'message_application_data')
ORDER BY (n_tup_ins + n_tup_upd + n_tup_del) DESC;

\echo ''
\echo '============================================================================'
\echo 'PART 4: CONCURRENCY PROBLEM DETECTION'
\echo '============================================================================'
\echo ''

\echo '----------------------------------------------------------------------------'
\echo '4.1. Transactions holding locks the longest'
\echo '----------------------------------------------------------------------------'

SELECT 
    pid,
    usename,
    application_name,
    state,
    backend_xid,
    backend_xmin,
    query_start,
    NOW() - query_start AS transaction_age,
    LEFT(query, 100) AS query
FROM pg_stat_activity
WHERE backend_xid IS NOT NULL 
   OR backend_xmin IS NOT NULL
ORDER BY query_start
LIMIT 20;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '4.2. Long-running transactions (>5 minutes) blocking VACUUM'
\echo '----------------------------------------------------------------------------'

SELECT 
    pid,
    usename,
    now() - xact_start AS xact_duration,
    now() - query_start AS query_duration,
    state,
    LEFT(query, 80) AS query
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
  AND now() - xact_start > interval '5 minutes'
ORDER BY xact_start;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '4.3. Connection pool status'
\echo '----------------------------------------------------------------------------'

SELECT 
    usename,
    application_name,
    client_addr,
    state,
    COUNT(*) AS connection_count
FROM pg_stat_activity
GROUP BY usename, application_name, client_addr, state
ORDER BY connection_count DESC;

\echo ''
\echo '============================================================================'
\echo 'PART 5: CONSTRAINT AND CONFLICT ANALYSIS'
\echo '============================================================================'
\echo ''

\echo '----------------------------------------------------------------------------'
\echo '5.1. UNIQUE/PRIMARY KEY constraints on pipeline tables'
\echo '----------------------------------------------------------------------------'

SELECT 
    tc.table_name,
    tc.constraint_name,
    tc.constraint_type,
    string_agg(kcu.column_name, ', ') AS columns
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu 
    ON tc.constraint_name = kcu.constraint_name
    AND tc.table_schema = kcu.table_schema
WHERE tc.constraint_type IN ('UNIQUE', 'PRIMARY KEY')
  AND tc.table_name IN ('entities', 'group_memberships', 'items', 
                        'entity_images', 'entity_relations',
                        'message_application_data', 'personal_details')
GROUP BY tc.table_name, tc.constraint_name, tc.constraint_type
ORDER BY tc.table_name, tc.constraint_type;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '5.2. Foreign keys on pipeline tables'
\echo '----------------------------------------------------------------------------'

SELECT 
    tc.table_name AS child_table,
    kcu.column_name AS fk_column,
    ccu.table_name AS parent_table,
    ccu.column_name AS parent_column,
    tc.constraint_name
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu 
    ON tc.constraint_name = kcu.constraint_name
JOIN information_schema.constraint_column_usage ccu 
    ON ccu.constraint_name = tc.constraint_name
WHERE tc.constraint_type = 'FOREIGN KEY'
  AND tc.table_name IN ('entities', 'group_memberships', 'items',
                        'entity_images', 'message_application_data')
ORDER BY tc.table_name;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '5.3. Foreign keys without indexes'
\echo '----------------------------------------------------------------------------'

SELECT 
    tc.table_name,
    kcu.column_name AS fk_column,
    CASE 
        WHEN EXISTS (
            SELECT 1 FROM pg_indexes 
            WHERE tablename = tc.table_name 
              AND indexdef LIKE '%' || kcu.column_name || '%'
        ) THEN 'INDEXED'
        ELSE 'NOT INDEXED - potential bottleneck'
    END AS index_status
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu 
    ON tc.constraint_name = kcu.constraint_name
WHERE tc.constraint_type = 'FOREIGN KEY'
  AND tc.table_name IN ('entities', 'group_memberships', 'items',
                        'entity_images', 'message_application_data')
ORDER BY index_status DESC, tc.table_name;

\echo ''
\echo '============================================================================'
\echo 'PART 6: WAL AND CHECKPOINT STATISTICS'
\echo '============================================================================'
\echo ''

\echo '----------------------------------------------------------------------------'
\echo '6.1. Checkpoint statistics'
\echo '----------------------------------------------------------------------------'

SELECT 
    checkpoints_timed,
    checkpoints_req,
    ROUND(checkpoint_write_time::numeric / 1000, 2) AS checkpoint_write_sec,
    ROUND(checkpoint_sync_time::numeric / 1000, 2) AS checkpoint_sync_sec,
    buffers_checkpoint,
    buffers_clean,
    maxwritten_clean,
    buffers_backend,
    buffers_backend_fsync,
    buffers_alloc
FROM pg_stat_bgwriter;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '6.2. Performance-related settings'
\echo '----------------------------------------------------------------------------'

SELECT name, setting, unit, short_desc
FROM pg_settings
WHERE name IN (
    'shared_buffers',
    'effective_cache_size', 
    'work_mem',
    'maintenance_work_mem',
    'max_connections',
    'max_parallel_workers_per_gather',
    'random_page_cost',
    'effective_io_concurrency',
    'checkpoint_completion_target',
    'wal_buffers',
    'default_statistics_target',
    'lock_timeout',
    'deadlock_timeout',
    'statement_timeout'
)
ORDER BY name;

\echo ''
\echo '============================================================================'
\echo 'PART 7: QUERY PERFORMANCE (requires pg_stat_statements)'
\echo '============================================================================'
\echo ''

\echo '----------------------------------------------------------------------------'
\echo '7.0. Check if pg_stat_statements is available and LOADED'
\echo '----------------------------------------------------------------------------'

SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements')
             AND current_setting('shared_preload_libraries') LIKE '%pg_stat_statements%'
        THEN 'pg_stat_statements is INSTALLED and LOADED - queries below will work'
        WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements')
        THEN 'pg_stat_statements is INSTALLED but NOT LOADED - add to shared_preload_libraries in postgresql.conf and restart'
        ELSE 'pg_stat_statements NOT INSTALLED'
    END AS extension_status,
    current_setting('shared_preload_libraries') AS shared_preload_libraries;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '7.1. Top queries by total execution time'
\echo '      (SKIP if pg_stat_statements not loaded)'
\echo '----------------------------------------------------------------------------'

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements')
       AND current_setting('shared_preload_libraries') LIKE '%pg_stat_statements%' THEN
        EXECUTE '
            SELECT 
                calls,
                ROUND(total_exec_time::numeric / 1000, 2) AS total_seconds,
                ROUND(mean_exec_time::numeric / 1000, 4) AS mean_seconds,
                rows,
                ROUND(100.0 * shared_blks_hit / NULLIF(shared_blks_hit + shared_blks_read, 0), 2) AS cache_hit_pct,
                LEFT(query, 100) AS query_preview
            FROM pg_stat_statements
            WHERE query NOT LIKE ''%pg_stat%''
            ORDER BY total_exec_time DESC
            LIMIT 20';
    ELSE
        RAISE NOTICE 'SKIPPED: pg_stat_statements not loaded in shared_preload_libraries';
    END IF;
END $$;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '7.2. Queries with worst cache hit ratio'
\echo '      (SKIP if pg_stat_statements not loaded)'
\echo '----------------------------------------------------------------------------'

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements')
       AND current_setting('shared_preload_libraries') LIKE '%pg_stat_statements%' THEN
        EXECUTE '
            SELECT 
                calls,
                shared_blks_hit,
                shared_blks_read,
                ROUND(100.0 * shared_blks_hit / NULLIF(shared_blks_hit + shared_blks_read, 0), 2) AS cache_hit_pct,
                LEFT(query, 100) AS query_preview
            FROM pg_stat_statements
            WHERE (shared_blks_hit + shared_blks_read) > 1000
              AND query NOT LIKE ''%pg_stat%''
            ORDER BY cache_hit_pct ASC
            LIMIT 20';
    ELSE
        RAISE NOTICE 'SKIPPED: pg_stat_statements not loaded in shared_preload_libraries';
    END IF;
END $$;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '7.3. Queries affecting pipeline tables (entities, group_memberships, items)'
\echo '      (SKIP if pg_stat_statements not loaded)'
\echo '----------------------------------------------------------------------------'

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements')
       AND current_setting('shared_preload_libraries') LIKE '%pg_stat_statements%' THEN
        EXECUTE '
            SELECT 
                calls,
                ROUND(total_exec_time::numeric / 1000, 2) AS total_seconds,
                ROUND(mean_exec_time::numeric / 1000, 4) AS mean_seconds,
                rows,
                LEFT(query, 120) AS query_preview
            FROM pg_stat_statements
            WHERE query LIKE ''%entities%''
               OR query LIKE ''%group_memberships%''
               OR query LIKE ''%items%''
            ORDER BY total_exec_time DESC
            LIMIT 30';
    ELSE
        RAISE NOTICE 'SKIPPED: pg_stat_statements not loaded in shared_preload_libraries';
    END IF;
END $$;

\echo ''
\echo '============================================================================'
\echo 'PART 8: MISSING UNIQUE CONSTRAINTS (required for ON CONFLICT)'
\echo '============================================================================'
\echo ''

\echo '----------------------------------------------------------------------------'
\echo '8.1. Check for UNIQUE constraints on pipeline tables'
\echo '----------------------------------------------------------------------------'

SELECT 
    tc.table_name,
    tc.constraint_name,
    tc.constraint_type,
    STRING_AGG(kcu.column_name, ', ' ORDER BY kcu.ordinal_position) AS columns
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu 
    ON tc.constraint_name = kcu.constraint_name 
    AND tc.table_schema = kcu.table_schema
WHERE tc.constraint_type IN ('UNIQUE', 'PRIMARY KEY')
  AND tc.table_name IN ('entities', 'group_memberships', 'items', 
                        'entity_images', 'personal_details', 'phone_appdata',
                        'entity_relations')
GROUP BY tc.table_name, tc.constraint_name, tc.constraint_type
ORDER BY tc.table_name, tc.constraint_type;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '8.2. RECOMMENDED UNIQUE CONSTRAINTS (for ON CONFLICT to work)'
\echo '----------------------------------------------------------------------------'

SELECT 'entities' AS table_name, 
       'UNIQUE(scrapping_id, type) WHERE status != ''5''' AS recommended_constraint,
       CASE WHEN EXISTS (
           SELECT 1 FROM pg_indexes 
           WHERE tablename = 'entities' 
           AND indexdef LIKE '%scrapping_id%' 
           AND indexdef LIKE '%UNIQUE%'
       ) THEN 'EXISTS' ELSE 'MISSING' END AS status
UNION ALL
SELECT 'group_memberships', 
       'UNIQUE(group_id, member_id) WHERE status != ''5''',
       CASE WHEN EXISTS (
           SELECT 1 FROM pg_indexes 
           WHERE tablename = 'group_memberships' 
           AND indexdef LIKE '%group_id%member_id%' 
           AND indexdef LIKE '%UNIQUE%'
       ) THEN 'EXISTS' ELSE 'MISSING' END
UNION ALL
SELECT 'items', 
       'UNIQUE(scrapping_id) WHERE status != ''5'' AND scrapping_id IS NOT NULL',
       CASE WHEN EXISTS (
           SELECT 1 FROM pg_indexes 
           WHERE tablename = 'items' 
           AND indexdef LIKE '%scrapping_id%' 
           AND indexdef LIKE '%UNIQUE%'
       ) THEN 'EXISTS' ELSE 'MISSING' END
UNION ALL
SELECT 'entity_images', 
       'UNIQUE(entity_id, checksum) WHERE status != ''5''',
       CASE WHEN EXISTS (
           SELECT 1 FROM pg_indexes 
           WHERE tablename = 'entity_images' 
           AND indexdef LIKE '%entity_id%checksum%' 
           AND indexdef LIKE '%UNIQUE%'
       ) THEN 'EXISTS' ELSE 'MISSING' END
UNION ALL
SELECT 'entity_relations', 
       'UNIQUE(from_entity, to_entity, relation_type) WHERE status != ''5''',
       CASE WHEN EXISTS (
           SELECT 1 FROM pg_indexes 
           WHERE tablename = 'entity_relations' 
           AND indexdef LIKE '%UNIQUE%'
       ) THEN 'EXISTS' ELSE 'MISSING' END;

\echo ''
\echo '============================================================================'
\echo 'PART 9: QUICK HEALTH CHECK SUMMARY'
\echo '============================================================================'
\echo ''

\echo '----------------------------------------------------------------------------'
\echo '9.1. Health metrics summary'
\echo '----------------------------------------------------------------------------'

SELECT 'Active connections' AS metric, 
       COUNT(*)::text AS value 
FROM pg_stat_activity 
WHERE state != 'idle'

UNION ALL

SELECT 'Blocked queries' AS metric, 
       COUNT(*)::text AS value 
FROM pg_stat_activity 
WHERE wait_event_type = 'Lock'

UNION ALL

SELECT 'Long transactions (>5min)' AS metric, 
       COUNT(*)::text AS value 
FROM pg_stat_activity 
WHERE xact_start IS NOT NULL 
  AND now() - xact_start > interval '5 minutes'

UNION ALL

SELECT 'Tables needing VACUUM (>10k dead)' AS metric, 
       COUNT(*)::text AS value 
FROM pg_stat_user_tables 
WHERE n_dead_tup > 10000

UNION ALL

SELECT 'Seq scans on large tables (>100k rows)' AS metric, 
       COUNT(*)::text AS value 
FROM pg_stat_user_tables 
WHERE seq_scan > 1000 
  AND n_live_tup > 100000

UNION ALL

SELECT 'Connection usage' AS metric,
       COUNT(*)::text || ' / ' || current_setting('max_connections') AS value
FROM pg_stat_activity

UNION ALL

SELECT 'Cache hit ratio' AS metric,
       ROUND(100.0 * SUM(blks_hit) / NULLIF(SUM(blks_hit) + SUM(blks_read), 0), 2)::text || '%' AS value
FROM pg_stat_database;

\echo ''
\echo '============================================================================'
\echo 'END OF DIAGNOSTIC SCRIPT'
\echo '============================================================================'
\echo ''
