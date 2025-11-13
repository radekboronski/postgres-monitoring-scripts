\set ECHO queries


\echo ''
\echo '============================================================================'
\echo 'PART 1: CURRENT PARAMETER VALUES'
\echo '============================================================================'
\echo ''



SELECT 
    name,
    setting,
    unit,
    CASE 
        WHEN name = 'max_connections' THEN setting || ' connections'
        WHEN unit = 'ms' THEN setting || ' ms (' || (setting::numeric/1000) || ' seconds)'
        WHEN unit = 's' THEN setting || ' seconds'
        WHEN setting = '0' THEN '0 (DISABLED - no timeout)'
        ELSE setting
    END as current_value,
    CASE 
        WHEN name = 'max_connections' AND setting::integer > 2000 
        THEN 'TOO HIGH - Allows unlimited connection leak'
        WHEN name = 'max_connections' AND setting::integer > 500 
        THEN 'HIGH - Should be lower'
        WHEN name = 'statement_timeout' AND setting::integer = 0 
        THEN 'DISABLED - No query timeout (could hang forever)'
        WHEN name = 'statement_timeout' AND setting::integer < 10000 AND setting::integer > 0
        THEN 'TOO LOW - Killing queries on bloated tables'
        WHEN name = 'lock_timeout' AND setting::integer = 0 
        THEN 'DISABLED - Connections wait forever for locks'
        WHEN name = 'idle_in_transaction_session_timeout' AND setting::integer = 0 
        THEN 'DISABLED - Idle transactions never timeout'
        WHEN name = 'idle_in_transaction_session_timeout' AND setting::integer < 30000 AND setting::integer > 0
        THEN 'TOO LOW - Killing normal transactions'
        ELSE 'OK'
    END as assessment
FROM pg_settings
WHERE name IN (
    'max_connections',
    'statement_timeout',
    'lock_timeout',
    'idle_in_transaction_session_timeout'
)
ORDER BY name;



\echo ''
\echo '============================================================================'
\echo 'PART 2: IMPACT ANALYSIS - How Parameters Affect '
\echo '============================================================================'
\echo ''



\echo '2.1. Connection usage vs limit'
\echo ''

WITH connection_stats AS (
    SELECT COUNT(*) as current_connections
    FROM pg_stat_activity
    WHERE datname = current_database()
),
connection_limit AS (
    SELECT setting::integer as max_conn
    FROM pg_settings
    WHERE name = 'max_connections'
)
SELECT 
    'CONNECTION ANALYSIS' as analysis,
    cs.current_connections,
    cl.max_conn as max_connections,
    ROUND((cs.current_connections::numeric / cl.max_conn * 100), 2) as usage_pct,
    CASE 
        WHEN cs.current_connections::numeric / cl.max_conn > 0.9 
        THEN 'CRITICAL - Near limit, will hit max soon'
        WHEN cs.current_connections::numeric / cl.max_conn > 0.5 
        THEN 'HIGH - Using over 50% of available connections'
        WHEN cs.current_connections::numeric / cl.max_conn < 0.1 
        THEN 'LOW - Using <10% of limit, max_connections too high'
        ELSE 'MODERATE'
    END as status,
    CASE 
        WHEN cs.current_connections > 1000 AND cs.current_connections::numeric / cl.max_conn < 0.5
        THEN 'You have ' || cs.current_connections || ' connections but max is ' || cl.max_conn || ' - connection leak hidden by high limit'
        WHEN cs.current_connections > 200
        THEN cs.current_connections || ' connections is too many - likely connection leak'
        ELSE 'Connection count seems reasonable'
    END as interpretation
FROM connection_stats cs, connection_limit cl;



\echo '2.2. Statement timeout vs table bloat'
\echo ''

WITH timeout_setting AS (
    SELECT setting::integer as timeout_ms
    FROM pg_settings
    WHERE name = 'statement_timeout'
),
bloated_tables AS (
    SELECT 
        COUNT(*) as bloated_count,
        SUM(n_dead_tup) as total_dead_tuples
    FROM pg_stat_user_tables
    WHERE (n_dead_tup::numeric / NULLIF(n_live_tup, 0)) > 0.2
)
SELECT 
    'STATEMENT TIMEOUT ANALYSIS' as analysis,
    ts.timeout_ms,
    CASE 
        WHEN ts.timeout_ms = 0 THEN 'DISABLED - queries can run forever'
        ELSE (ts.timeout_ms::numeric / 1000) || ' seconds'
    END as timeout_value,
    bt.bloated_count as tables_with_20pct_bloat,
    bt.total_dead_tuples,
    CASE 
        WHEN ts.timeout_ms > 0 AND ts.timeout_ms < 10000 AND bt.bloated_count > 0
        THEN 'PROBLEM: Timeout ' || (ts.timeout_ms/1000) || 's too low for ' || bt.bloated_count || ' bloated tables'
        WHEN ts.timeout_ms = 0 AND bt.bloated_count > 0
        THEN 'WARNING: No timeout but tables bloated - queries may hang'
        WHEN ts.timeout_ms > 0 AND ts.timeout_ms >= 30000
        THEN 'OK: Timeout reasonable for current table condition'
        ELSE 'UNKNOWN'
    END as impact_assessment
FROM timeout_setting ts, bloated_tables bt;



\echo '2.3. Idle in transaction timeout analysis'
\echo ''

WITH timeout_setting AS (
    SELECT setting::integer as timeout_ms
    FROM pg_settings
    WHERE name = 'idle_in_transaction_session_timeout'
),
idle_in_trans AS (
    SELECT COUNT(*) as idle_trans_count
    FROM pg_stat_activity
    WHERE state = 'idle in transaction'
      AND datname = current_database()
)
SELECT 
    'IDLE IN TRANSACTION ANALYSIS' as analysis,
    ts.timeout_ms,
    CASE 
        WHEN ts.timeout_ms = 0 THEN 'DISABLED - transactions can stay idle forever'
        ELSE (ts.timeout_ms::numeric / 1000) || ' seconds'
    END as timeout_value,
    it.idle_trans_count as current_idle_in_transaction,
    CASE 
        WHEN ts.timeout_ms > 0 AND ts.timeout_ms < 30000
        THEN 'TOO LOW: ' || (ts.timeout_ms/1000) || 's timeout kills normal wallet operations'
        WHEN ts.timeout_ms = 0 AND it.idle_trans_count > 10
        THEN 'PROBLEM: No timeout and ' || it.idle_trans_count || ' idle transactions accumulating'
        WHEN ts.timeout_ms >= 60000
        THEN 'OK: ' || (ts.timeout_ms/1000) || 's allows time for normal operations'
        ELSE 'MODERATE'
    END as impact_assessment
FROM timeout_setting ts, idle_in_trans it;



\echo '2.4. Lock timeout and blocked queries'
\echo ''

WITH timeout_setting AS (
    SELECT setting::integer as timeout_ms
    FROM pg_settings
    WHERE name = 'lock_timeout'
),
blocked_queries AS (
    SELECT COUNT(*) as blocked_count
    FROM pg_stat_activity
    WHERE wait_event_type = 'Lock'
      AND datname = current_database()
)
SELECT 
    'LOCK TIMEOUT ANALYSIS' as analysis,
    ts.timeout_ms,
    CASE 
        WHEN ts.timeout_ms = 0 THEN 'DISABLED - queries wait forever for locks'
        ELSE (ts.timeout_ms::numeric / 1000) || ' seconds'
    END as timeout_value,
    bq.blocked_count as currently_blocked_queries,
    CASE 
        WHEN ts.timeout_ms = 0 AND bq.blocked_count > 0
        THEN 'PROBLEM: No timeout, ' || bq.blocked_count || ' queries waiting (will wait forever)'
        WHEN ts.timeout_ms = 0
        THEN 'DISABLED: Queries can wait forever for locks - connections accumulate'
        WHEN ts.timeout_ms > 0 AND ts.timeout_ms <= 10000
        THEN 'OK: Queries timeout after ' || (ts.timeout_ms/1000) || 's instead of waiting forever'
        ELSE 'REASONABLE'
    END as impact_assessment
FROM timeout_setting ts, blocked_queries bq;



\echo ''
\echo '============================================================================'
\echo 'PART 3: RECOMMENDED CHANGES'
\echo '============================================================================'
\echo ''


\echo '3.1. Current vs Recommended parameter values'
\echo ''

SELECT 
    name as parameter,
    setting as current_value,
    CASE name
        WHEN 'max_connections' THEN '200'
        WHEN 'statement_timeout' THEN '30000'
        WHEN 'lock_timeout' THEN '10000'
        WHEN 'idle_in_transaction_session_timeout' THEN '60000'
    END as recommended_value,
    CASE name
        WHEN 'max_connections' THEN 'connections'
        WHEN 'statement_timeout' THEN 'ms (30 seconds)'
        WHEN 'lock_timeout' THEN 'ms (10 seconds)'
        WHEN 'idle_in_transaction_session_timeout' THEN 'ms (60 seconds)'
    END as unit,
    CASE name
        WHEN 'max_connections' 
        THEN 'Forces app to fix connection leak. Current: ' || setting || ' allows ' || (setting::integer - 200) || ' extra leaked connections'
        WHEN 'statement_timeout' 
        THEN 'Allows queries time to complete on bloated tables. Current: ' || (setting::numeric/1000) || 's may be too aggressive'
        WHEN 'lock_timeout' 
        THEN 'Prevents forever waits. Current: ' || CASE WHEN setting::integer = 0 THEN 'DISABLED (waits forever)' ELSE (setting::numeric/1000) || 's' END
        WHEN 'idle_in_transaction_session_timeout' 
        THEN 'Allows time for operations. Current: ' || (setting::numeric/1000) || 's may kill normal transactions'
    END as reason_for_change
FROM pg_settings
WHERE name IN (
    'max_connections',
    'statement_timeout',
    'lock_timeout',
    'idle_in_transaction_session_timeout'
)
ORDER BY name;



\echo ''
\echo '============================================================================'
\echo 'PART 4: RISK ASSESSMENT FOR CHANGES'
\echo '============================================================================'
\echo ''



WITH current_state AS (
    SELECT 
        (SELECT COUNT(*) FROM pg_stat_activity WHERE datname = current_database()) as conn_count,
        (SELECT setting::integer FROM pg_settings WHERE name = 'max_connections') as max_conn,
        (SELECT setting::integer FROM pg_settings WHERE name = 'statement_timeout') as stmt_timeout,
        (SELECT setting::integer FROM pg_settings WHERE name = 'lock_timeout') as lock_timeout,
        (SELECT setting::integer FROM pg_settings WHERE name = 'idle_in_transaction_session_timeout') as idle_timeout
)
SELECT 
    'max_connections: ' || max_conn || ' -> 200' as change,
    CASE 
        WHEN conn_count > 200 
        THEN 'HIGH RISK: ' || (conn_count - 200) || ' connections will be rejected immediately'
        ELSE 'LOW RISK: Current ' || conn_count || ' < 200 limit'
    END as impact,
    CASE 
        WHEN conn_count > 200 
        THEN 'App will get "too many connections" errors until leak fixed'
        ELSE 'No immediate impact'
    END as action_needed
FROM current_state

UNION ALL

SELECT 
    'statement_timeout: ' || CASE WHEN stmt_timeout = 0 THEN 'DISABLED' ELSE stmt_timeout::text END || ' -> 30000' as change,
    CASE 
        WHEN stmt_timeout > 0 AND stmt_timeout < 30000 
        THEN 'POSITIVE: Fewer queries killed, fewer rollbacks'
        WHEN stmt_timeout = 0 
        THEN 'MODERATE: Adds timeout where none existed'
        ELSE 'MINIMAL'
    END as impact,
    'Queries have more time to complete' as action_needed
FROM current_state

UNION ALL

SELECT 
    'lock_timeout: ' || CASE WHEN lock_timeout = 0 THEN 'DISABLED' ELSE lock_timeout::text END || ' -> 10000' as change,
    CASE 
        WHEN lock_timeout = 0 
        THEN 'MODERATE: Queries waiting for locks will now timeout'
        ELSE 'MINIMAL'
    END as impact,
    'App needs to handle lock timeout errors and retry' as action_needed
FROM current_state

UNION ALL

SELECT 
    'idle_in_transaction_session_timeout: ' || CASE WHEN idle_timeout = 0 THEN 'DISABLED' ELSE idle_timeout::text END || ' -> 60000' as change,
    CASE 
        WHEN idle_timeout > 0 AND idle_timeout < 60000 
        THEN 'POSITIVE: Fewer transactions killed, fewer rollbacks'
        WHEN idle_timeout = 0 
        THEN 'MODERATE: Adds timeout where none existed'
        ELSE 'MINIMAL'
    END as impact,
    'Transactions have more time for normal operations' as action_needed
FROM current_state;

