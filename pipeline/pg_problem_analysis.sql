\set ECHO queries

-- Set schema search path (change 'test' to your schema if different)
SET search_path TO test, public;

\echo ''
\echo '============================================================================'
\echo 'Pipeline-Specific Problem Analysis'
\echo 'Telegram/WhatsApp Ingestion'
\echo '============================================================================'
\echo 'Purpose: Detect concurrency and data integrity issues'
\echo '============================================================================'
\echo ''

\echo '============================================================================'
\echo 'PROBLEM 1: PARALLEL BULK INSERT INTO entities'
\echo 'Multiple processes simultaneously inserting to the same table'
\echo '============================================================================'
\echo ''

\echo '----------------------------------------------------------------------------'
\echo '1.1. Duplicate scrapping_id (evidence of race condition)'
\echo '----------------------------------------------------------------------------'

SELECT 
    scrapping_id,
    type,
    COUNT(*) AS cnt,
    array_agg(id ORDER BY id) AS duplicate_ids,
    array_agg(status) AS statuses,
    MIN(system_creation_time) AS first_created,
    MAX(system_creation_time) AS last_created
FROM entities
WHERE status != '5'
GROUP BY scrapping_id, type
HAVING COUNT(*) > 1
ORDER BY cnt DESC
LIMIT 50;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '1.2. Insert frequency over time (last hour)'
\echo '----------------------------------------------------------------------------'

SELECT 
    date_trunc('minute', system_creation_time) AS minute,
    COUNT(*) AS inserts_per_minute,
    COUNT(DISTINCT type) AS entity_types,
    COUNT(*) FILTER (WHERE type = 'group') AS groups_inserted,
    COUNT(*) FILTER (WHERE type != 'group') AS members_inserted
FROM entities
WHERE system_creation_time > NOW() - interval '1 hour'
GROUP BY date_trunc('minute', system_creation_time)
ORDER BY minute DESC;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '1.3. Conflict frequency - same scrapping_id attempted multiple times'
\echo '----------------------------------------------------------------------------'

WITH recent_entities AS (
    SELECT 
        scrapping_id,
        COUNT(*) AS attempt_count,
        MIN(system_creation_time) AS first_attempt,
        MAX(system_creation_time) AS last_attempt
    FROM entities
    WHERE system_creation_time > NOW() - interval '24 hours'
    GROUP BY scrapping_id
    HAVING COUNT(*) > 1
)
SELECT 
    attempt_count,
    COUNT(*) AS entities_with_this_count,
    ROUND(AVG(EXTRACT(EPOCH FROM (last_attempt - first_attempt))), 2) AS avg_seconds_between
FROM recent_entities
GROUP BY attempt_count
ORDER BY attempt_count DESC;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '1.4. Closest duplicates (race condition timing)'
\echo '----------------------------------------------------------------------------'

SELECT 
    e1.scrapping_id,
    e1.id AS first_id,
    e2.id AS second_id,
    e1.system_creation_time AS first_created,
    e2.system_creation_time AS second_created,
    EXTRACT(EPOCH FROM (e2.system_creation_time - e1.system_creation_time)) AS seconds_apart
FROM entities e1
JOIN entities e2 ON e1.scrapping_id = e2.scrapping_id 
    AND e1.type = e2.type 
    AND e1.id < e2.id
WHERE e1.status != '5' AND e2.status != '5'
  AND e1.system_creation_time > NOW() - interval '24 hours'
ORDER BY seconds_apart ASC
LIMIT 20;

\echo ''
\echo '============================================================================'
\echo 'PROBLEM 2: GROUP MEMBERSHIPS - RACE CONDITIONS'
\echo '============================================================================'
\echo ''

\echo '----------------------------------------------------------------------------'
\echo '2.1. Duplicates in group_memberships'
\echo '----------------------------------------------------------------------------'

SELECT 
    group_id,
    member_id,
    COUNT(*) AS cnt,
    array_agg(id ORDER BY id) AS duplicate_ids,
    array_agg(status) AS statuses
FROM group_memberships
WHERE status != '5'
GROUP BY group_id, member_id
HAVING COUNT(*) > 1
ORDER BY cnt DESC
LIMIT 50;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '2.2. Membership churn - same member added/removed multiple times'
\echo '----------------------------------------------------------------------------'

SELECT 
    gm.group_id,
    gm.member_id,
    e.scrapping_id AS member_scrapping_id,
    COUNT(*) AS total_records,
    COUNT(*) FILTER (WHERE gm.status = '1') AS active_count,
    COUNT(*) FILTER (WHERE gm.status = '2') AS past_member_count,
    COUNT(*) FILTER (WHERE gm.status = '5') AS deleted_count
FROM group_memberships gm
JOIN entities e ON gm.member_id = e.id
GROUP BY gm.group_id, gm.member_id, e.scrapping_id
HAVING COUNT(*) > 2
ORDER BY COUNT(*) DESC
LIMIT 30;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '2.3. Membership status changes frequency'
\echo '----------------------------------------------------------------------------'

SELECT 
    group_id,
    COUNT(*) AS total_memberships,
    COUNT(*) FILTER (WHERE membership_status = '1') AS active,
    COUNT(*) FILTER (WHERE membership_status = '2') AS past,
    MAX(system_update_time) AS last_update
FROM group_memberships
WHERE status != '5'
GROUP BY group_id
ORDER BY total_memberships DESC
LIMIT 20;

\echo ''
\echo '============================================================================'
\echo 'PROBLEM 3: ITEMS (MESSAGES) - BULK INSERT CONFLICTS'
\echo '============================================================================'
\echo ''

\echo '----------------------------------------------------------------------------'
\echo '3.1. Duplicate messages'
\echo '----------------------------------------------------------------------------'

SELECT 
    scrapping_id,
    group_id,
    COUNT(*) AS cnt,
    array_agg(id ORDER BY id) AS duplicate_ids,
    array_agg(sender_id) AS senders
FROM items
WHERE status != '5'
  AND scrapping_id IS NOT NULL
GROUP BY scrapping_id, group_id
HAVING COUNT(*) > 1
LIMIT 50;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '3.2. Items table load statistics'
\echo '----------------------------------------------------------------------------'

SELECT 
    relname AS table_name,
    n_tup_ins AS total_inserts,
    n_tup_upd AS total_updates,
    n_tup_del AS total_deletes,
    n_live_tup AS live_rows,
    n_dead_tup AS dead_rows,
    ROUND(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS bloat_pct,
    pg_size_pretty(pg_total_relation_size(relid)) AS total_size
FROM pg_stat_user_tables
WHERE relname = 'items';

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '3.3. Message insertion rate by group (last 24h)'
\echo '----------------------------------------------------------------------------'

SELECT 
    group_id,
    COUNT(*) AS messages_count,
    MIN(timestamp) AS earliest_msg,
    MAX(timestamp) AS latest_msg,
    COUNT(DISTINCT sender_id) AS unique_senders
FROM items
WHERE status = '1'
  AND system_creation_time > NOW() - interval '24 hours'
GROUP BY group_id
ORDER BY messages_count DESC
LIMIT 20;

\echo ''
\echo '============================================================================'
\echo 'PROBLEM 4: INHERITANCE QUERIES - MASS UPDATE IMPACT'
\echo '============================================================================'
\echo ''

\echo '----------------------------------------------------------------------------'
\echo '4.1. Members affected by inheritance updates'
\echo '----------------------------------------------------------------------------'

SELECT 
    'Members affected by inheritance' AS metric,
    COUNT(*) AS count
FROM group_memberships gm
JOIN entities e ON gm.member_id = e.id
WHERE gm.status != '5' AND e.status != '5';

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '4.2. Groups with most members (highest inheritance impact)'
\echo '----------------------------------------------------------------------------'

SELECT 
    gm.group_id,
    e.name AS group_name,
    COUNT(gm.member_id) AS member_count,
    COUNT(*) FILTER (WHERE gm.is_admin = TRUE) AS admin_count
FROM group_memberships gm
JOIN entities e ON gm.group_id = e.id AND e.type = 'group'
WHERE gm.status != '5' AND e.status != '5'
GROUP BY gm.group_id, e.name
ORDER BY member_count DESC
LIMIT 20;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '4.3. Entities table UPDATE efficiency'
\echo '----------------------------------------------------------------------------'

SELECT 
    relname,
    n_tup_upd AS updates,
    n_tup_hot_upd AS hot_updates,
    CASE WHEN n_tup_upd > 0 
         THEN ROUND(100.0 * n_tup_hot_upd / n_tup_upd, 2) 
         ELSE 0 
    END AS hot_update_pct,
    seq_scan,
    idx_scan,
    n_live_tup AS row_count
FROM pg_stat_user_tables
WHERE relname = 'entities';

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '4.4. Risk score distribution'
\echo '----------------------------------------------------------------------------'

SELECT 
    risk_score,
    COUNT(*) AS entity_count,
    COUNT(*) FILTER (WHERE type = 'group') AS group_count,
    COUNT(*) FILTER (WHERE type != 'group') AS member_count
FROM entities
WHERE status != '5'
GROUP BY risk_score
ORDER BY risk_score NULLS FIRST;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '4.5. Classification update frequency (last 24h)'
\echo '----------------------------------------------------------------------------'

SELECT 
    date_trunc('hour', system_update_time) AS hour,
    COUNT(*) AS updates,
    COUNT(*) FILTER (WHERE classifications IS NOT NULL) AS with_classifications,
    COUNT(*) FILTER (WHERE sub_classifications IS NOT NULL) AS with_sub_classifications
FROM entities
WHERE system_update_time > NOW() - interval '24 hours'
GROUP BY date_trunc('hour', system_update_time)
ORDER BY hour DESC;

\echo ''
\echo '============================================================================'
\echo 'PROBLEM 5: BLACKLIST QUERIES - CASCADE UPDATE IMPACT'
\echo '============================================================================'
\echo ''

\echo '----------------------------------------------------------------------------'
\echo '5.1. Blacklisted records per table'
\echo '----------------------------------------------------------------------------'

SELECT 'entities' AS table_name, COUNT(*) AS blacklisted_records
FROM entities WHERE status = '5'
UNION ALL
SELECT 'group_memberships', COUNT(*) FROM group_memberships WHERE status = '5'
UNION ALL
SELECT 'items', COUNT(*) FROM items WHERE status = '5'
UNION ALL
SELECT 'entity_relations', COUNT(*) FROM entity_relations WHERE status = '5'
UNION ALL
SELECT 'entity_images', COUNT(*) FROM entity_images WHERE status = '5'
UNION ALL
SELECT 'personal_details', COUNT(*) FROM personal_details WHERE status = '5'
UNION ALL
SELECT 'phone_appdata', COUNT(*) FROM phone_appdata WHERE status = '5'
ORDER BY blacklisted_records DESC;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '5.2. Blacklist operation frequency (last 24h)'
\echo '----------------------------------------------------------------------------'

SELECT 
    date_trunc('hour', system_update_time) AS hour,
    COUNT(*) FILTER (WHERE status = '5') AS blacklisted,
    COUNT(*) FILTER (WHERE status = '1') AS active
FROM entities
WHERE system_update_time > NOW() - interval '24 hours'
GROUP BY date_trunc('hour', system_update_time)
ORDER BY hour DESC;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '5.3. Orphaned records after blacklist'
\echo '----------------------------------------------------------------------------'

SELECT 'Orphaned group_memberships (missing member)' AS issue,
       COUNT(*) AS count
FROM group_memberships gm
WHERE NOT EXISTS (SELECT 1 FROM entities e WHERE e.id = gm.member_id AND e.status != '5')
  AND gm.status != '5'
UNION ALL
SELECT 'Orphaned group_memberships (missing group)' AS issue,
       COUNT(*) AS count
FROM group_memberships gm
WHERE NOT EXISTS (SELECT 1 FROM entities e WHERE e.id = gm.group_id AND e.status != '5')
  AND gm.status != '5'
UNION ALL
SELECT 'Orphaned items (missing group)' AS issue,
       COUNT(*) AS count
FROM items i
WHERE NOT EXISTS (SELECT 1 FROM entities e WHERE e.id = i.group_id AND e.status != '5')
  AND i.status != '5';

\echo ''
\echo '============================================================================'
\echo 'PROBLEM 6: AI SUMMARY QUERIES - LATERAL JOIN PERFORMANCE'
\echo '============================================================================'
\echo ''

\echo '----------------------------------------------------------------------------'
\echo '6.1. Messages per group (LATERAL JOIN cost estimation)'
\echo '----------------------------------------------------------------------------'

SELECT 
    group_id,
    COUNT(*) AS message_count,
    COUNT(*) FILTER (WHERE media_url IS NOT NULL AND media_url != '') AS with_media,
    COUNT(DISTINCT sender_id) AS unique_senders
FROM items
WHERE status = '1'
GROUP BY group_id
ORDER BY message_count DESC
LIMIT 20;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '6.2. message_application_data relationship'
\echo '----------------------------------------------------------------------------'

SELECT 
    'Items with application data' AS metric,
    COUNT(DISTINCT i.id) AS count
FROM items i
JOIN message_application_data mad ON mad.item_id = i.id
WHERE i.status = '1' AND mad.status != '5'
UNION ALL
SELECT 'Items without application data' AS metric,
       COUNT(*) AS count
FROM items i
WHERE i.status = '1'
  AND NOT EXISTS (SELECT 1 FROM message_application_data mad WHERE mad.item_id = i.id AND mad.status != '5');

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '6.3. Multiple application_data per item (expensive LATERAL)'
\echo '----------------------------------------------------------------------------'

SELECT 
    item_id,
    COUNT(*) AS app_data_count
FROM message_application_data
WHERE status != '5'
GROUP BY item_id
HAVING COUNT(*) > 1
ORDER BY app_data_count DESC
LIMIT 20;

\echo ''
\echo '============================================================================'
\echo 'PROBLEM 7: ENTITY IMAGES - CHECKSUM CONFLICTS'
\echo '============================================================================'
\echo ''

\echo '----------------------------------------------------------------------------'
\echo '7.1. Duplicate images per entity'
\echo '----------------------------------------------------------------------------'

SELECT 
    entity_id,
    checksum,
    COUNT(*) AS cnt,
    array_agg(id ORDER BY id) AS duplicate_ids
FROM entity_images
WHERE status != '5'
GROUP BY entity_id, checksum
HAVING COUNT(*) > 1
LIMIT 20;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '7.2. Entities with multiple images'
\echo '----------------------------------------------------------------------------'

SELECT 
    entity_id,
    COUNT(*) AS image_count,
    COUNT(DISTINCT checksum) AS unique_checksums
FROM entity_images
WHERE status != '5'
GROUP BY entity_id
HAVING COUNT(*) > 1
ORDER BY image_count DESC
LIMIT 20;

\echo ''
\echo '============================================================================'
\echo 'PROBLEM 8: ENTITY RELATIONS - DUPLICATE RELATIONS'
\echo '============================================================================'
\echo ''

\echo '----------------------------------------------------------------------------'
\echo '8.1. Duplicate entity relations'
\echo '----------------------------------------------------------------------------'

SELECT 
    from_entity,
    to_entity,
    relation_type,
    COUNT(*) AS cnt
FROM entity_relations
WHERE status != '5'
GROUP BY from_entity, to_entity, relation_type
HAVING COUNT(*) > 1
ORDER BY cnt DESC
LIMIT 20;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '8.2. Self-referencing relations (potential data issue)'
\echo '----------------------------------------------------------------------------'

SELECT 
    id,
    from_entity,
    to_entity,
    relation_type
FROM entity_relations
WHERE from_entity = to_entity
  AND status != '5';

\echo ''
\echo '============================================================================'
\echo 'PROBLEM 9: PERSONAL DETAILS AND PHONE APPDATA DUPLICATES'
\echo '============================================================================'
\echo ''

\echo '----------------------------------------------------------------------------'
\echo '9.1. Multiple personal_details per entity'
\echo '----------------------------------------------------------------------------'

SELECT 
    entity_id,
    COUNT(*) AS record_count,
    array_agg(DISTINCT username) AS usernames
FROM personal_details
WHERE status != '5'
GROUP BY entity_id
HAVING COUNT(*) > 1
ORDER BY record_count DESC
LIMIT 20;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '9.2. Multiple phone_appdata per entity'
\echo '----------------------------------------------------------------------------'

SELECT 
    entity_id,
    COUNT(*) AS record_count
FROM phone_appdata
WHERE status != '5'
GROUP BY entity_id
HAVING COUNT(*) > 1
ORDER BY record_count DESC
LIMIT 20;

\echo ''
\echo '============================================================================'
\echo 'PROBLEM 10: COUNTRIES TABLE - LOOKUP EFFICIENCY'
\echo '============================================================================'
\echo ''

\echo '----------------------------------------------------------------------------'
\echo '10.1. Countries table statistics'
\echo '----------------------------------------------------------------------------'

SELECT 
    COUNT(*) AS total_countries,
    COUNT(*) FILTER (WHERE status = '1') AS active_countries
FROM countries;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '10.2. Countries table indexes'
\echo '----------------------------------------------------------------------------'

SELECT 
    indexname,
    indexdef
FROM pg_indexes
WHERE tablename = 'countries';

\echo ''
\echo '============================================================================'
\echo 'PROBLEM 11: QUERY EXECUTION PLANS (EXPLAIN ANALYZE)'
\echo 'WARNING: These execute actual queries - run on test data or replica'
\echo '============================================================================'
\echo ''

\echo '----------------------------------------------------------------------------'
\echo '11.1. LATERAL JOIN cost analysis (get_group_messages pattern)'
\echo '----------------------------------------------------------------------------'

-- Get a sample group_id for testing
DO $$
DECLARE
    v_group_id INTEGER;
BEGIN
    SELECT id INTO v_group_id FROM entities WHERE type = 'group' AND status = '1' LIMIT 1;
    
    IF v_group_id IS NOT NULL THEN
        RAISE NOTICE 'Testing with group_id: %', v_group_id;
        RAISE NOTICE 'Run this EXPLAIN manually to see full plan:';
        RAISE NOTICE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) SELECT i.*, mad.text_body FROM items i LEFT JOIN LATERAL (SELECT text_body FROM message_application_data WHERE item_id = i.id AND status != ''5'' LIMIT 1) mad ON true WHERE i.group_id = % AND i.status = ''1'' ORDER BY i.timestamp DESC LIMIT 100;', v_group_id;
    ELSE
        RAISE NOTICE 'No groups found for testing';
    END IF;
END $$;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '11.2. Entity lookup by scrapping_id - index usage check'
\echo '----------------------------------------------------------------------------'

EXPLAIN (COSTS ON)
SELECT id, name, type, risk_score
FROM entities
WHERE scrapping_id = 'test_scrapping_id_12345'
  AND type = 'member'
  AND status != '5';

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '11.3. Group memberships lookup - index usage check'
\echo '----------------------------------------------------------------------------'

EXPLAIN (COSTS ON)
SELECT gm.id, gm.member_id, gm.membership_status
FROM group_memberships gm
WHERE gm.group_id = 1
  AND gm.status != '5';

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '11.4. Items by group - index usage check'
\echo '----------------------------------------------------------------------------'

EXPLAIN (COSTS ON)
SELECT id, sender_id, timestamp, risk_score
FROM items
WHERE group_id = 1
  AND status = '1'
ORDER BY timestamp DESC
LIMIT 100;

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '11.5. Inheritance UPDATE impact estimation'
\echo '----------------------------------------------------------------------------'

-- Show how many rows would be affected by inheritance update
SELECT 
    'Rows affected by single group inheritance UPDATE' AS metric,
    COUNT(*) AS count
FROM group_memberships gm
JOIN entities e ON gm.member_id = e.id
WHERE gm.group_id = (SELECT id FROM entities WHERE type = 'group' AND status = '1' LIMIT 1)
  AND gm.status != '5'
  AND e.status != '5';

\echo ''
\echo '============================================================================'
\echo 'PROBLEM 12: RECOMMENDED FIXES (DDL statements)'
\echo '============================================================================'
\echo ''

\echo '----------------------------------------------------------------------------'
\echo '12.1. Missing UNIQUE indexes for ON CONFLICT (copy and run manually)'
\echo '----------------------------------------------------------------------------'

SELECT '-- Run these to enable ON CONFLICT handling:' AS recommendation
UNION ALL
SELECT ''
UNION ALL
SELECT '-- 1. Entities: prevent duplicate scrapping_id'
UNION ALL
SELECT 'CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS idx_entities_scrapping_id_type_unique'
UNION ALL
SELECT '    ON entities(scrapping_id, type) WHERE status != ''5'';'
UNION ALL
SELECT ''
UNION ALL
SELECT '-- 2. Group memberships: prevent duplicate member in group'
UNION ALL
SELECT 'CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS idx_group_memberships_unique'
UNION ALL
SELECT '    ON group_memberships(group_id, member_id) WHERE status != ''5'';'
UNION ALL
SELECT ''
UNION ALL
SELECT '-- 3. Items: prevent duplicate messages'
UNION ALL
SELECT 'CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS idx_items_scrapping_id_unique'
UNION ALL
SELECT '    ON items(scrapping_id) WHERE status != ''5'' AND scrapping_id IS NOT NULL;'
UNION ALL
SELECT ''
UNION ALL
SELECT '-- 4. Entity images: prevent duplicate images'
UNION ALL
SELECT 'CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS idx_entity_images_unique'
UNION ALL
SELECT '    ON entity_images(entity_id, checksum) WHERE status != ''5'';'
UNION ALL
SELECT ''
UNION ALL
SELECT '-- 5. Entity relations: prevent duplicate relations'
UNION ALL
SELECT 'CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS idx_entity_relations_unique'
UNION ALL
SELECT '    ON entity_relations(from_entity, to_entity, relation_type) WHERE status != ''5'';';

\echo ''
\echo '----------------------------------------------------------------------------'
\echo '12.2. Performance indexes (copy and run manually)'
\echo '----------------------------------------------------------------------------'

SELECT '-- Additional indexes for query performance:' AS recommendation
UNION ALL
SELECT ''
UNION ALL
SELECT '-- Partial index for active entities only'
UNION ALL
SELECT 'CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_entities_active'
UNION ALL
SELECT '    ON entities(id, type, scrapping_id) WHERE status != ''5'';'
UNION ALL
SELECT ''
UNION ALL
SELECT '-- Items by group with timestamp (for pagination)'
UNION ALL
SELECT 'CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_items_group_timestamp'
UNION ALL
SELECT '    ON items(group_id, timestamp DESC) WHERE status = ''1'';'
UNION ALL
SELECT ''
UNION ALL
SELECT '-- Message application data lookup'
UNION ALL
SELECT 'CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_mad_item_active'
UNION ALL
SELECT '    ON message_application_data(item_id) WHERE status != ''5'';';

\echo ''
\echo '============================================================================'
\echo 'SUMMARY REPORT'
\echo '============================================================================'
\echo ''

\echo '----------------------------------------------------------------------------'
\echo 'Problem counts summary'
\echo '----------------------------------------------------------------------------'

SELECT 
    'Entities with duplicate scrapping_id' AS problem,
    COUNT(*) AS count
FROM (
    SELECT scrapping_id 
    FROM entities 
    WHERE status != '5' 
    GROUP BY scrapping_id, type 
    HAVING COUNT(*) > 1
) dup

UNION ALL

SELECT 
    'Duplicate group_memberships' AS problem,
    COUNT(*) AS count
FROM (
    SELECT group_id, member_id 
    FROM group_memberships 
    WHERE status != '5' 
    GROUP BY group_id, member_id 
    HAVING COUNT(*) > 1
) dup

UNION ALL

SELECT 
    'Duplicate items (scrapping_id)' AS problem,
    COUNT(*) AS count
FROM (
    SELECT scrapping_id 
    FROM items 
    WHERE status != '5' AND scrapping_id IS NOT NULL
    GROUP BY scrapping_id 
    HAVING COUNT(*) > 1
) dup

UNION ALL

SELECT 
    'Tables with bloat > 20%' AS problem,
    COUNT(*) AS count
FROM pg_stat_user_tables
WHERE n_dead_tup > 0 
  AND ROUND(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) > 20

UNION ALL

SELECT 
    'Tables with more seq scans than idx scans' AS problem,
    COUNT(*) AS count
FROM pg_stat_user_tables
WHERE seq_scan > COALESCE(idx_scan, 0)
  AND n_live_tup > 10000

UNION ALL

SELECT 
    'Orphaned group_memberships' AS problem,
    COUNT(*) AS count
FROM group_memberships gm
WHERE gm.status != '5'
  AND (
    NOT EXISTS (SELECT 1 FROM entities e WHERE e.id = gm.member_id AND e.status != '5')
    OR NOT EXISTS (SELECT 1 FROM entities e WHERE e.id = gm.group_id AND e.status != '5')
  );

\echo ''
\echo '============================================================================'
\echo 'END OF PROBLEM ANALYSIS'
\echo '============================================================================'
\echo ''
