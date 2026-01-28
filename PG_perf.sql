-- ============================================================================
-- PostgreSQL Performance Report - Complete Verification Script
-- ============================================================================

-- ============================================================================
-- SECTION 1: Executive Summary
-- ============================================================================

-- 1.1 Database size and cache hit ratios
SELECT 
    'Section 1: Executive Summary' AS section,
    pg_size_pretty(pg_database_size(current_database())) AS database_size,
    (SELECT ROUND(100.0 * sum(heap_blks_hit) / nullif(sum(heap_blks_hit) + sum(heap_blks_read), 0), 2) 
     FROM pg_statio_user_tables) AS table_cache_hit_ratio,
    (SELECT ROUND(100.0 * sum(idx_blks_hit) / nullif(sum(idx_blks_hit) + sum(idx_blks_read), 0), 2) 
     FROM pg_statio_user_indexes) AS index_cache_hit_ratio;

-- 1.2 Connections
SELECT 
    'Connections' AS metric,
    count(*) AS total_connections,
    count(*) FILTER (WHERE state = 'active') AS active,
    count(*) FILTER (WHERE state = 'idle') AS idle,
    count(*) FILTER (WHERE state = 'idle in transaction') AS idle_in_transaction
FROM pg_stat_activity
WHERE datname = current_database();

-- 1.3 Transaction ID age
SELECT 
    'XID Age' AS metric,
    datname,
    age(datfrozenxid) AS xid_age,
    CASE 
        WHEN age(datfrozenxid) > 1500000000 THEN 'CRITICAL'
        WHEN age(datfrozenxid) > 1000000000 THEN 'WARNING'
        ELSE 'OK' 
    END AS status
FROM pg_database
WHERE datname = current_database();


-- ============================================================================
-- SECTION 2: Slowest Queries (requires pg_stat_statements)
-- ============================================================================

-- 2.1 Top 10 by mean execution time
SELECT 
    'Section 2: Slowest Queries (by mean time)' AS section,
    substring(query, 1, 100) AS query_preview,
    calls,
    ROUND((mean_exec_time / 1000)::numeric, 2) AS mean_time_sec,
    ROUND((total_exec_time / 1000 / 3600)::numeric, 2) AS total_time_hrs,
    rows
FROM backend_reconciliation_db.pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
ORDER BY mean_exec_time DESC
LIMIT 10;

-- 2.2 Top 10 by total execution time
SELECT 
    'Section 2: Slowest Queries (by total time)' AS section,
    substring(query, 1, 100) AS query_preview,
    calls,
    ROUND((mean_exec_time / 1000)::numeric, 2) AS mean_time_sec,
    ROUND((total_exec_time / 1000 / 3600)::numeric, 2) AS total_time_hrs,
    rows
FROM backend_reconciliation_db.pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
ORDER BY total_exec_time DESC
LIMIT 10;


-- ============================================================================
-- SECTION 3: Zero-Efficiency Indexes (0% efficiency)
-- ============================================================================

SELECT 
    'Section 3: Zero-Efficiency Indexes' AS section,
    schemaname,
    relname AS table_name,
    indexrelname AS index_name,
    idx_scan AS scans,
    idx_tup_read AS tuples_read,
    idx_tup_fetch AS tuples_fetched,
    CASE WHEN idx_tup_read > 0 
         THEN ROUND(100.0 * idx_tup_fetch / idx_tup_read, 2) 
         ELSE 0 END AS efficiency_pct,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
FROM pg_stat_user_indexes
WHERE indexrelname IN (
    'idx_transaction_trace_unsynced_settle',
    'idx_transaction_trace_unsynced_trade',
    'idx_transaction_trace_unsynced_accrual'
)
ORDER BY idx_tup_read DESC;


-- ============================================================================
-- SECTION 4: Low-Efficiency Indexes (< 10%)
-- ============================================================================

SELECT 
    'Section 4: Low-Efficiency Indexes' AS section,
    schemaname,
    relname AS table_name,
    indexrelname AS index_name,
    idx_scan AS scans,
    idx_tup_read AS tuples_read,
    idx_tup_fetch AS tuples_fetched,
    CASE WHEN idx_tup_read > 0 
         THEN ROUND(100.0 * idx_tup_fetch / idx_tup_read, 2) 
         ELSE 0 END AS efficiency_pct,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
FROM pg_stat_user_indexes
WHERE idx_tup_read > 1000000
  AND idx_tup_fetch::float / NULLIF(idx_tup_read, 0) < 0.10
ORDER BY idx_tup_read DESC;


-- ============================================================================
-- SECTION 5: Index Bloat (estimation without pgstattuple)
-- ============================================================================

SELECT 
    'Section 5: Index Bloat (candidates for REINDEX)' AS section,
    schemaname,
    relname AS table_name,
    indexrelname AS index_name,
    idx_scan AS scans,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    pg_relation_size(indexrelid) AS size_bytes
FROM pg_stat_user_indexes
WHERE schemaname IN ('backend_reconciliation_db', 'subaccounting_db')
  AND pg_relation_size(indexrelid) > 500 * 1024 * 1024
  AND idx_scan > 0  -- Index IS used (bloat, not unused)
ORDER BY pg_relation_size(indexrelid) DESC
LIMIT 20;


-- ============================================================================
-- SECTION 6: Duplicate/Covered Indexes
-- ============================================================================

WITH index_cols AS (
    SELECT 
        i.indexrelid,
        i.indrelid,
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
    WHERE n.nspname IN ('backend_reconciliation_db', 'subaccounting_db')
    GROUP BY i.indexrelid, i.indrelid, n.nspname, t.relname, idx.relname
)
SELECT 
    'Section 6: Duplicate/Covered Indexes' AS section,
    a.schema_name,
    a.table_name,
    a.index_name AS redundant_index,
    b.index_name AS covered_by_index,
    a.columns AS redundant_columns,
    b.columns AS covering_columns,
    pg_size_pretty(a.index_size) AS redundant_size,
    pg_size_pretty(b.index_size) AS covering_size
FROM index_cols a
JOIN index_cols b ON a.indrelid = b.indrelid 
    AND a.indexrelid < b.indexrelid
    AND (a.columns = b.columns OR a.columns <@ b.columns)
ORDER BY a.index_size DESC;


-- ============================================================================
-- SECTION 7: Unused Indexes (0 scans, > 50 MB)
-- ============================================================================

SELECT 
    'Section 7: Unused Indexes' AS section,
    schemaname,
    relname AS table_name,
    indexrelname AS index_name,
    idx_scan,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    pg_relation_size(indexrelid) AS size_bytes,
    CASE 
        WHEN indexrelname LIKE '%_pkey' THEN 'PRIMARY KEY - DO NOT DROP'
        ELSE 'Candidate for DROP'
    END AS recommendation
FROM pg_stat_user_indexes
WHERE idx_scan = 0
  AND pg_relation_size(indexrelid) > 50 * 1024 * 1024
ORDER BY pg_relation_size(indexrelid) DESC;


-- ============================================================================
-- SECTION 8: Tables Requiring Vacuum
-- ============================================================================

SELECT 
    'Section 8: Tables Requiring Vacuum' AS section,
    schemaname,
    relname AS table_name,
    n_dead_tup AS dead_rows,
    n_live_tup AS live_rows,
    CASE WHEN n_live_tup > 0 
         THEN ROUND(100.0 * n_dead_tup / n_live_tup, 2) 
         ELSE 0 END AS dead_ratio_pct,
    last_vacuum,
    last_autovacuum,
    CASE 
        WHEN n_dead_tup > n_live_tup THEN 'VACUUM FULL recommended'
        WHEN n_dead_tup > 50 + (0.2 * n_live_tup) THEN 'VACUUM ANALYZE recommended'
        ELSE 'OK'
    END AS recommendation
FROM pg_stat_user_tables
WHERE schemaname IN ('backend_reconciliation_db', 'subaccounting_db')
  AND (n_dead_tup > 10000 OR n_dead_tup > n_live_tup * 0.1)
ORDER BY n_dead_tup DESC;


-- ============================================================================
-- SECTION 9: Tables Never Vacuumed/Analyzed (autovacuum disabled)
-- ============================================================================

SELECT 
    'Section 9: Tables Never Vacuumed/Analyzed' AS section,
    schemaname,
    relname AS table_name,
    pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
    n_live_tup,
    n_dead_tup,
    last_vacuum,
    last_autovacuum,
    last_analyze,
    last_autoanalyze,
    CASE 
        WHEN last_autovacuum IS NULL AND last_autoanalyze IS NULL 
        THEN 'Autovacuum likely DISABLED - enable it'
        ELSE 'OK'
    END AS recommendation
FROM pg_stat_user_tables
WHERE schemaname IN ('backend_reconciliation_db', 'subaccounting_db')
  AND last_autovacuum IS NULL
  AND last_autoanalyze IS NULL
  AND pg_total_relation_size(relid) > 500 * 1024 * 1024
ORDER BY pg_total_relation_size(relid) DESC;


-- ============================================================================
-- SECTION 10: Empty Tables Check (post-TRUNCATE detection)
-- ============================================================================

SELECT 
    'Section 10: Empty/Truncated Tables' AS section,
    schemaname,
    relname AS table_name,
    pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
    n_live_tup,
    n_tup_ins AS total_inserts,
    n_tup_del AS total_deletes,
    CASE 
        WHEN n_live_tup = 0 AND n_tup_ins > 1000000 AND n_tup_del < n_tup_ins * 0.5
        THEN 'Likely TRUNCATED - stats are historical'
        ELSE 'OK'
    END AS status
FROM pg_stat_user_tables
WHERE schemaname IN ('backend_reconciliation_db', 'subaccounting_db')
  AND n_live_tup = 0
  AND n_tup_ins > 100000
ORDER BY n_tup_ins DESC;


-- ============================================================================
-- SECTION 11: Autovacuum Settings Check
-- ============================================================================

SELECT 
    'Section 11: Autovacuum Settings' AS section,
    n.nspname AS schema_name,
    c.relname AS table_name,
    c.reloptions,
    CASE 
        WHEN c.reloptions::text LIKE '%autovacuum_enabled=false%' 
        THEN 'DISABLED - needs fix'
        ELSE 'Default (enabled)'
    END AS autovacuum_status
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname IN ('backend_reconciliation_db', 'subaccounting_db')
  AND c.relkind = 'r'
  AND (c.reloptions IS NOT NULL OR n.nspname = 'subaccounting_db')
ORDER BY n.nspname, c.relname;


-- ============================================================================
-- SUMMARY: Counts per section
-- ============================================================================

SELECT 'SUMMARY' AS section, 'Zero-efficiency indexes' AS metric, 
    COUNT(*) AS count 
FROM pg_stat_user_indexes 
WHERE idx_tup_read > 0 AND idx_tup_fetch = 0

UNION ALL

SELECT 'SUMMARY', 'Low-efficiency indexes (<10%)', COUNT(*) 
FROM pg_stat_user_indexes 
WHERE idx_tup_read > 1000000 
  AND idx_tup_fetch::float / NULLIF(idx_tup_read, 0) < 0.10

UNION ALL

SELECT 'SUMMARY', 'Unused indexes (0 scans, >50MB)', COUNT(*) 
FROM pg_stat_user_indexes 
WHERE idx_scan = 0 
  AND pg_relation_size(indexrelid) > 50 * 1024 * 1024

UNION ALL

SELECT 'SUMMARY', 'Tables needing vacuum', COUNT(*) 
FROM pg_stat_user_tables 
WHERE schemaname IN ('backend_reconciliation_db', 'subaccounting_db')
  AND (n_dead_tup > 10000 OR n_dead_tup > n_live_tup * 0.1)

UNION ALL

SELECT 'SUMMARY', 'Tables with autovacuum disabled', COUNT(*) 
FROM pg_stat_user_tables 
WHERE schemaname IN ('backend_reconciliation_db', 'subaccounting_db')
  AND last_autovacuum IS NULL 
  AND last_autoanalyze IS NULL
  AND pg_total_relation_size(relid) > 500 * 1024 * 1024;

