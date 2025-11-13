\set ECHO queries


\echo ''
\echo '============================================================================'
\echo 'PART 1: OVERALL BLOAT SUMMARY'
\echo '============================================================================'
\echo ''

SELECT 
    'DATABASE SUMMARY' as analysis,
    COUNT(*) as total_tables,
    SUM(n_live_tup) as total_live_tuples,
    SUM(n_dead_tup) as total_dead_tuples,
    ROUND((SUM(n_dead_tup)::numeric / NULLIF(SUM(n_live_tup), 0) * 100), 2) as avg_dead_pct,
    COUNT(*) FILTER (WHERE n_dead_tup::numeric / NULLIF(n_live_tup, 0) > 0.50) as tables_over_50pct_dead,
    COUNT(*) FILTER (WHERE n_dead_tup::numeric / NULLIF(n_live_tup, 0) > 0.20) as tables_over_20pct_dead,
    COUNT(*) FILTER (WHERE n_dead_tup::numeric / NULLIF(n_live_tup, 0) > 0.10) as tables_over_10pct_dead,
    pg_size_pretty(SUM(pg_total_relation_size(schemaname||'.'||relname))) as total_database_size
FROM pg_stat_user_tables;



\echo ''
\echo '============================================================================'
\echo 'PART 2: TOP BLOATED TABLES'
\echo '============================================================================'
\echo ''


SELECT 
    'TOP BLOATED TABLES' as analysis,
    schemaname || '.' || relname as table_name,
    n_live_tup as live_tuples,
    n_dead_tup as dead_tuples,
    ROUND((n_dead_tup::numeric / NULLIF(n_live_tup, 0) * 100), 2) as dead_pct,
    n_tup_ins as total_inserts,
    n_tup_upd as total_updates,
    n_tup_del as total_deletes,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||relname)) as total_size,
    COALESCE(to_char(last_vacuum, 'YYYY-MM-DD HH24:MI:SS'), 'NEVER') as last_manual_vacuum,
    COALESCE(to_char(last_autovacuum, 'YYYY-MM-DD HH24:MI:SS'), 'NEVER') as last_autovacuum,
    CASE 
        WHEN n_dead_tup::numeric / NULLIF(n_live_tup, 0) > 0.50 THEN 'CRITICAL'
        WHEN n_dead_tup::numeric / NULLIF(n_live_tup, 0) > 0.20 THEN 'HIGH'
        WHEN n_dead_tup::numeric / NULLIF(n_live_tup, 0) > 0.10 THEN 'MODERATE'
        ELSE 'LOW'
    END as bloat_severity
FROM pg_stat_user_tables
WHERE n_dead_tup > 0
ORDER BY n_dead_tup DESC
LIMIT 20;



\echo ''
\echo '============================================================================'
\echo 'PART 3: WALLETS TABLE DETAILED ANALYSIS'
\echo '============================================================================'
\echo ''


\echo '3.1. Wallets table bloat analysis'
\echo ''

SELECT 
    'WALLETS TABLE ANALYSIS' as analysis,
    schemaname || '.' || relname as table_name,
    n_live_tup as live_tuples,
    n_dead_tup as dead_tuples,
    ROUND((n_dead_tup::numeric / NULLIF(n_live_tup, 0) * 100), 2) as dead_pct,
    n_tup_ins as total_inserts_ever,
    n_tup_upd as total_updates_ever,
    n_tup_del as total_deletes_ever,
    n_tup_hot_upd as hot_updates,
    ROUND((n_tup_hot_upd::numeric / NULLIF(n_tup_upd, 0) * 100), 2) as hot_update_pct,
    pg_size_pretty(pg_relation_size(schemaname||'.'||relname)) as table_size,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||relname)) as total_size_with_indexes,
    COALESCE(to_char(last_vacuum, 'YYYY-MM-DD HH24:MI:SS'), 'NEVER') as last_manual_vacuum,
    COALESCE(to_char(last_autovacuum, 'YYYY-MM-DD HH24:MI:SS'), 'NEVER') as last_autovacuum,
    COALESCE(EXTRACT(EPOCH FROM (now() - last_vacuum))::bigint / 86400, 9999) as days_since_manual_vacuum,
    COALESCE(EXTRACT(EPOCH FROM (now() - last_autovacuum))::bigint / 86400, 9999) as days_since_autovacuum
FROM pg_stat_user_tables
WHERE relname = 'wallets'
  AND schemaname = 'public';



\echo '3.2. Wallets table autovacuum configuration'
\echo ''

SELECT 
    'WALLETS AUTOVACUUM SETTINGS' as analysis,
    c.relname as table_name,
    c.reloptions as table_storage_parameters,
    COALESCE(
        (SELECT option_value 
         FROM pg_options_to_table(c.reloptions) 
         WHERE option_name = 'autovacuum_vacuum_scale_factor'),
        (SELECT setting FROM pg_settings WHERE name = 'autovacuum_vacuum_scale_factor')
    ) as vacuum_scale_factor,
    COALESCE(
        (SELECT option_value 
         FROM pg_options_to_table(c.reloptions) 
         WHERE option_name = 'autovacuum_vacuum_threshold'),
        (SELECT setting FROM pg_settings WHERE name = 'autovacuum_vacuum_threshold')
    ) as vacuum_threshold,
    CASE 
        WHEN c.reloptions IS NULL 
        THEN 'Using database defaults (not optimized for high-activity table)'
        ELSE 'Table has custom settings'
    END as setting_status
FROM pg_class c
JOIN pg_namespace n ON c.relnamespace = n.oid
WHERE c.relname = 'wallets'
  AND n.nspname = 'public';



\echo ''
\echo '============================================================================'
\echo 'PART 4: WALLET_TRANSACTIONS PARTITION ANALYSIS'
\echo '============================================================================'
\echo ''



SELECT 
    'WALLET_TRANSACTIONS PARTITIONS' as analysis,
    relname as partition_name,
    n_live_tup as live_tuples,
    n_dead_tup as dead_tuples,
    ROUND((n_dead_tup::numeric / NULLIF(n_live_tup, 0) * 100), 2) as dead_pct,
    n_tup_ins as inserts,
    n_tup_upd as updates,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||relname)) as size,
    COALESCE(to_char(last_vacuum, 'YYYY-MM-DD HH24:MI:SS'), 'NEVER') as last_manual_vacuum,
    COALESCE(to_char(last_autovacuum, 'YYYY-MM-DD HH24:MI:SS'), 'NEVER') as last_autovacuum,
    CASE 
        WHEN last_vacuum IS NULL AND last_autovacuum IS NULL THEN 'NEVER VACUUMED'
        WHEN COALESCE(last_vacuum, last_autovacuum) < now() - INTERVAL '7 days' THEN 'OVERDUE'
        ELSE 'RECENT'
    END as vacuum_status
FROM pg_stat_user_tables
WHERE schemaname = 'auditing'
  AND relname LIKE 'wallet_transactions_p%'
ORDER BY relname DESC
LIMIT 15;




\echo ''
\echo '============================================================================'
\echo 'PART 5: BLOAT CORRELATION WITH ROLLBACKS'
\echo '============================================================================'
\echo ''


WITH db_stats AS (
    SELECT 
        xact_commit,
        xact_rollback,
        ROUND((100.0 * xact_rollback / NULLIF(xact_commit + xact_rollback, 0))::numeric, 2) AS rollback_pct
    FROM pg_stat_database
    WHERE datname = current_database()
),
table_stats AS (
    SELECT 
        SUM(n_dead_tup) as total_dead_tuples,
        COUNT(*) FILTER (WHERE n_dead_tup > 0) as tables_with_dead_tuples
    FROM pg_stat_user_tables
)
SELECT 
    'ROLLBACK CORRELATION' as analysis,
    ds.xact_commit as total_commits,
    ds.xact_rollback as total_rollbacks,
    ds.rollback_pct,
    ts.total_dead_tuples,
    ts.tables_with_dead_tuples,
    CASE 
        WHEN ds.xact_rollback > ts.total_dead_tuples * 100
        THEN 'High rollback rate is major contributor to dead tuple accumulation'
        WHEN ds.xact_rollback > ts.total_dead_tuples * 10
        THEN 'Rollbacks contributing significantly to dead tuples'
        ELSE 'Dead tuples mostly from UPDATEs, not rollbacks'
    END as correlation_assessment
FROM db_stats ds, table_stats ts;



\echo ''
\echo '============================================================================'
\echo 'PART 6: VACUUM EFFECTIVENESS'
\echo '============================================================================'
\echo ''


\echo '6.1. Tables never vacuumed (highest risk)'
\echo ''

SELECT 
    'NEVER VACUUMED' as analysis,
    schemaname || '.' || relname as table_name,
    n_dead_tup as dead_tuples,
    ROUND((n_dead_tup::numeric / NULLIF(n_live_tup, 0) * 100), 2) as dead_pct,
    n_tup_ins + n_tup_upd + n_tup_del as total_modifications,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||relname)) as total_size,
    'NEVER' as last_vacuum_status
FROM pg_stat_user_tables
WHERE last_vacuum IS NULL 
  AND last_autovacuum IS NULL
  AND n_dead_tup > 0
ORDER BY n_dead_tup DESC
LIMIT 20;


\echo '6.2. Tables with oldest vacuum dates'
\echo ''

SELECT 
    'VACUUM OVERDUE' as analysis,
    schemaname || '.' || relname as table_name,
    n_dead_tup as dead_tuples,
    ROUND((n_dead_tup::numeric / NULLIF(n_live_tup, 0) * 100), 2) as dead_pct,
    COALESCE(to_char(last_vacuum, 'YYYY-MM-DD'), 'NEVER') as last_manual_vacuum,
    COALESCE(to_char(last_autovacuum, 'YYYY-MM-DD'), 'NEVER') as last_autovacuum,
    COALESCE(
        EXTRACT(EPOCH FROM (now() - GREATEST(COALESCE(last_vacuum, '1970-01-01'), COALESCE(last_autovacuum, '1970-01-01'))))::bigint / 86400,
        9999
    ) as days_since_any_vacuum,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||relname)) as total_size
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
ORDER BY GREATEST(COALESCE(last_vacuum, '1970-01-01'), COALESCE(last_autovacuum, '1970-01-01')) ASC
LIMIT 20;


\echo ''
\echo '============================================================================'
\echo 'PART 7: VACUUM RECOMMENDATIONS'
\echo '============================================================================'
\echo ''


\echo '7.1. VACUUM priority list (top 20 tables)'
\echo ''

SELECT 
    'VACUUM PRIORITIES' as analysis,
    schemaname || '.' || relname as table_name,
    n_dead_tup as dead_tuples,
    ROUND((n_dead_tup::numeric / NULLIF(n_live_tup, 0) * 100), 2) as dead_pct,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||relname)) as total_size,
    CASE 
        WHEN n_dead_tup::numeric / NULLIF(n_live_tup, 0) > 0.50 AND n_dead_tup > 1000000
        THEN 'P0 - CRITICAL: Run VACUUM immediately'
        WHEN n_dead_tup::numeric / NULLIF(n_live_tup, 0) > 0.20 AND n_dead_tup > 100000
        THEN 'P1 - HIGH: Run VACUUM within 24 hours'
        WHEN n_dead_tup::numeric / NULLIF(n_live_tup, 0) > 0.10 AND n_dead_tup > 10000
        THEN 'P2 - MODERATE: Schedule VACUUM this week'
        ELSE 'P3 - LOW: Monitor, VACUUM when convenient'
    END as priority,
    'VACUUM (ANALYZE, VERBOSE) ' || schemaname || '.' || relname || ';' as vacuum_command
FROM pg_stat_user_tables
WHERE n_dead_tup > 0
ORDER BY 
    CASE 
        WHEN n_dead_tup::numeric / NULLIF(n_live_tup, 0) > 0.50 AND n_dead_tup > 1000000 THEN 1
        WHEN n_dead_tup::numeric / NULLIF(n_live_tup, 0) > 0.20 AND n_dead_tup > 100000 THEN 2
        WHEN n_dead_tup::numeric / NULLIF(n_live_tup, 0) > 0.10 AND n_dead_tup > 10000 THEN 3
        ELSE 4
    END,
    n_dead_tup DESC
LIMIT 20;


\echo '7.2. Recommended autovacuum settings for high-activity tables'
\echo ''

SELECT 
    'AUTOVACUUM TUNING' as analysis,
    schemaname || '.' || relname as table_name,
    n_tup_ins + n_tup_upd + n_tup_del as total_modifications,
    'ALTER TABLE ' || schemaname || '.' || relname || ' SET (autovacuum_vacuum_scale_factor = 0.01, autovacuum_vacuum_threshold = 100);' as tuning_command
FROM pg_stat_user_tables
WHERE n_tup_ins + n_tup_upd + n_tup_del > 100000
ORDER BY n_tup_ins + n_tup_upd + n_tup_del DESC
LIMIT 10;


\echo ''
\echo '============================================================================'
\echo 'PART 8: BLOAT IMPACT ON PERFORMANCE'
\echo '============================================================================'
\echo ''



SELECT 
    'PERFORMANCE IMPACT' as analysis,
    schemaname || '.' || relname as table_name,
    n_live_tup as live_tuples,
    n_dead_tup as dead_tuples,
    ROUND((n_dead_tup::numeric / NULLIF(n_live_tup, 0) * 100), 2) as dead_pct,
    CASE 
        WHEN n_dead_tup::numeric / NULLIF(n_live_tup, 0) > 0.50
        THEN 'Queries 2-3x slower than necessary'
        WHEN n_dead_tup::numeric / NULLIF(n_live_tup, 0) > 0.20
        THEN 'Queries 1.5-2x slower than necessary'
        WHEN n_dead_tup::numeric / NULLIF(n_live_tup, 0) > 0.10
        THEN 'Queries 1.2-1.5x slower than necessary'
        ELSE 'Minimal performance impact'
    END as estimated_slowdown,
    CASE 
        WHEN n_dead_tup::numeric / NULLIF(n_live_tup, 0) > 0.20
        THEN 'May cause statement_timeout if timeout < 30s'
        ELSE 'Unlikely to cause timeout'
    END as timeout_risk
FROM pg_stat_user_tables
WHERE n_dead_tup > 10000
ORDER BY n_dead_tup DESC
LIMIT 20;

