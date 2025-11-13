\set ECHO queries


\echo ''
\echo '============================================================================'
\echo 'PART 1: ALL TABLES WITH CONSTRAINTS'
\echo '============================================================================'
\echo ''


SELECT 
    'ALL TABLES WITH CONSTRAINTS' as analysis,
    conrelid::regclass as table_name,
    COUNT(*) FILTER (WHERE contype = 'f') as foreign_keys,
    COUNT(*) FILTER (WHERE contype = 'c') as check_constraints,
    COUNT(*) FILTER (WHERE contype = 'u') as unique_constraints,
    COUNT(*) FILTER (WHERE contype = 'p') as primary_keys,
    COUNT(*) as total_constraints,
    (SELECT n_tup_ins FROM pg_stat_user_tables 
     WHERE (schemaname||'.'||relname)::regclass = conrelid) as inserts,
    (SELECT n_tup_upd FROM pg_stat_user_tables 
     WHERE (schemaname||'.'||relname)::regclass = conrelid) as updates,
    (SELECT n_tup_del FROM pg_stat_user_tables 
     WHERE (schemaname||'.'||relname)::regclass = conrelid) as deletes
FROM pg_constraint
WHERE conrelid IN (
    SELECT oid FROM pg_class 
    WHERE relnamespace IN (
        SELECT oid FROM pg_namespace 
        WHERE nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
    )
    AND relkind = 'r'
)
AND contype IN ('f', 'c', 'u', 'p')
GROUP BY conrelid
ORDER BY total_constraints DESC, 
         (SELECT n_tup_ins FROM pg_stat_user_tables 
          WHERE (schemaname||'.'||relname)::regclass = conrelid) DESC
LIMIT 30;
\echo ''
\echo ''
\echo ''

\echo ''
\echo '============================================================================'
\echo 'PART 2: TABLES WITH ACTIVITY AND CONSTRAINTS'
\echo '============================================================================'
\echo ''


SELECT 
    'TABLES WITH ACTIVITY' as analysis,
    t.schemaname || '.' || t.relname as table_name,
    t.n_tup_ins as inserts,
    t.n_tup_upd as updates,
    t.n_tup_del as deletes,
    t.n_tup_ins + t.n_tup_upd + t.n_tup_del as total_modifications,
    (SELECT COUNT(*) FROM pg_constraint 
     WHERE conrelid = (t.schemaname||'.'||t.relname)::regclass 
       AND contype = 'f') as foreign_keys,
    (SELECT COUNT(*) FROM pg_constraint 
     WHERE conrelid = (t.schemaname||'.'||t.relname)::regclass 
       AND contype = 'c') as check_constraints,
    (SELECT COUNT(*) FROM pg_constraint 
     WHERE conrelid = (t.schemaname||'.'||t.relname)::regclass 
       AND contype = 'u') as unique_constraints,
    (SELECT COUNT(*) FROM pg_constraint 
     WHERE conrelid = (t.schemaname||'.'||t.relname)::regclass 
       AND contype = 'p') as primary_keys
FROM pg_stat_user_tables t
WHERE t.n_tup_ins + t.n_tup_upd + t.n_tup_del > 0  -- ANY activity
ORDER BY total_modifications DESC
LIMIT 30;
\echo ''
\echo ''
\echo ''

\echo ''
\echo '============================================================================'
\echo 'PART 3: SPECIFIC TABLE CONSTRAINT DETAILS'
\echo '============================================================================'
\echo ''


SELECT 
    'WALLETS CONSTRAINTS' as analysis,
    conrelid::regclass as table_name,
    conname as constraint_name,
    CASE contype
        WHEN 'f' THEN 'FOREIGN_KEY'
        WHEN 'c' THEN 'CHECK'
        WHEN 'u' THEN 'UNIQUE'
        WHEN 'p' THEN 'PRIMARY_KEY'
    END as constraint_type,
    pg_get_constraintdef(oid) as definition,
    confrelid::regclass as references_table,
    CASE contype
        WHEN 'f' THEN 'Rollback if referenced row does not exist in ' || confrelid::regclass::text
        WHEN 'c' THEN 'Rollback if condition in definition is false'
        WHEN 'u' THEN 'Rollback if duplicate value inserted'
        WHEN 'p' THEN 'Rollback if duplicate primary key inserted'
    END as failure_scenario
FROM pg_constraint
WHERE conrelid::regclass::text LIKE '%wallets%'
    AND contype IN ('f', 'c', 'u', 'p')
ORDER BY contype, conname;

\echo ''
\echo '3.2. Constraint details for casino_transactions table'
\echo ''

SELECT 
    'CASINO_TRANSACTIONS CONSTRAINTS' as analysis,
    conrelid::regclass as table_name,
    conname as constraint_name,
    CASE contype
        WHEN 'f' THEN 'FOREIGN_KEY'
        WHEN 'c' THEN 'CHECK'
        WHEN 'u' THEN 'UNIQUE'
        WHEN 'p' THEN 'PRIMARY_KEY'
    END as constraint_type,
    pg_get_constraintdef(oid) as definition,
    confrelid::regclass as references_table,
    CASE contype
        WHEN 'f' THEN 'Rollback if referenced row does not exist in ' || confrelid::regclass::text
        WHEN 'c' THEN 'Rollback if condition in definition is false'
        WHEN 'u' THEN 'Rollback if duplicate value inserted'
        WHEN 'p' THEN 'Rollback if duplicate primary key inserted'
    END as failure_scenario
FROM pg_constraint
WHERE conrelid::regclass::text LIKE '%casino_transactions%'
    AND contype IN ('f', 'c', 'u', 'p')
ORDER BY contype, conname
LIMIT 20;
\echo ''
\echo ''
\echo ''


\echo ''
\echo '============================================================================'
\echo 'PART 4: HIGH ROLLBACK RISK ASSESSMENT'
\echo '============================================================================'
\echo ''


SELECT 
    'ROLLBACK RISK ANALYSIS' as analysis,
    c.table_name,
    c.constraint_count,
    t.n_tup_ins + t.n_tup_upd as write_operations,
    pg_size_pretty(pg_total_relation_size(c.table_name::regclass)) as table_size,
    CASE 
        WHEN c.constraint_count >= 5 AND (t.n_tup_ins + t.n_tup_upd) > 1000000000 
        THEN 'VERY_HIGH_RISK - Billions of writes + Many constraints'
        WHEN c.constraint_count >= 3 AND (t.n_tup_ins + t.n_tup_upd) > 100000000 
        THEN 'HIGH_RISK - Millions of writes + Multiple constraints'
        WHEN c.constraint_count >= 1 AND (t.n_tup_ins + t.n_tup_upd) > 10000000 
        THEN 'MODERATE_RISK - High writes + Some constraints'
        ELSE 'LOW_RISK'
    END as rollback_risk
FROM (
    SELECT 
        conrelid::regclass::text as table_name,
        COUNT(*) as constraint_count
    FROM pg_constraint
    WHERE contype IN ('f', 'c', 'u', 'p')
    GROUP BY conrelid
) c
JOIN pg_stat_user_tables t ON (t.schemaname||'.'||t.relname) = c.table_name
WHERE t.n_tup_ins + t.n_tup_upd > 0
ORDER BY 
    CASE 
        WHEN c.constraint_count >= 5 AND (t.n_tup_ins + t.n_tup_upd) > 1000000000 THEN 1
        WHEN c.constraint_count >= 3 AND (t.n_tup_ins + t.n_tup_upd) > 100000000 THEN 2
        WHEN c.constraint_count >= 1 AND (t.n_tup_ins + t.n_tup_upd) > 10000000 THEN 3
        ELSE 4
    END,
    t.n_tup_ins + t.n_tup_upd DESC
LIMIT 30;
\echo ''
\echo ''
\echo ''

\echo ''
\echo '============================================================================'
\echo 'PART 5: TABLES EXCLUDED BY COMMON FILTERS'
\echo '============================================================================'
\echo ''


SELECT 
    'EXCLUDED BY 1M FILTER' as analysis,
    schemaname || '.' || relname as table_name,
    n_tup_ins + n_tup_upd + n_tup_del as total_modifications,
    (SELECT COUNT(*) FROM pg_constraint 
     WHERE conrelid = (schemaname||'.'||relname)::regclass 
       AND contype IN ('f','c','u','p')) as constraint_count,
    CASE 
        WHEN (SELECT COUNT(*) FROM pg_constraint 
              WHERE conrelid = (schemaname||'.'||relname)::regclass 
                AND contype IN ('f','c','u','p')) > 0 
        THEN 'Has constraints - could cause rollbacks'
        ELSE 'No constraints'
    END as note
FROM pg_stat_user_tables
WHERE n_tup_ins + n_tup_upd + n_tup_del > 0 
    AND n_tup_ins + n_tup_upd + n_tup_del < 1000000
    AND (SELECT COUNT(*) FROM pg_constraint 
         WHERE conrelid = (schemaname||'.'||relname)::regclass 
           AND contype IN ('f','c','u','p')) > 0
ORDER BY total_modifications DESC
LIMIT 20;

