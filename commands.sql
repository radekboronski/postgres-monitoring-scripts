DROP TABLE IF EXISTS test_reviews CASCADE;
DROP TABLE IF EXISTS test_inventory CASCADE;
DROP TABLE IF EXISTS test_transactions CASCADE;
DROP TABLE IF EXISTS test_activity_logs CASCADE;
DROP TABLE IF EXISTS test_order_items CASCADE;
DROP TABLE IF EXISTS test_orders CASCADE;
DROP TABLE IF EXISTS test_products CASCADE;
DROP TABLE IF EXISTS test_categories CASCADE;
DROP TABLE IF EXISTS test_users CASCADE;

-- 2. Usuń wszystkie funkcje testowe
DROP FUNCTION IF EXISTS quick_test() CASCADE;
DROP FUNCTION IF EXISTS medium_test() CASCADE;
DROP FUNCTION IF EXISTS large_test() CASCADE;
DROP FUNCTION IF EXISTS initialize_complete_test_environment(INTEGER, INTEGER, INTEGER, INTEGER, INTEGER, INTEGER, INTEGER, INTEGER) CASCADE;
DROP FUNCTION IF EXISTS simulate_high_memory_queries(INTEGER) CASCADE;
DROP FUNCTION IF EXISTS simulate_write_load(INTEGER) CASCADE;
DROP FUNCTION IF EXISTS simulate_read_load_slow(INTEGER) CASCADE;
DROP FUNCTION IF EXISTS simulate_workload_avoiding_indexes(INTEGER) CASCADE;
DROP FUNCTION IF EXISTS simulate_workload_with_indexes(INTEGER) CASCADE;
DROP FUNCTION IF EXISTS create_all_test_indexes() CASCADE;
DROP FUNCTION IF EXISTS create_duplicate_indexes() CASCADE;
DROP FUNCTION IF EXISTS create_unused_indexes() CASCADE;
DROP FUNCTION IF EXISTS create_used_indexes() CASCADE;
DROP FUNCTION IF EXISTS generate_all_test_data(INTEGER, INTEGER, INTEGER, INTEGER, INTEGER) CASCADE;
DROP FUNCTION IF EXISTS generate_test_reviews(INTEGER) CASCADE;
DROP FUNCTION IF EXISTS generate_test_inventory() CASCADE;
DROP FUNCTION IF EXISTS generate_test_transactions() CASCADE;
DROP FUNCTION IF EXISTS generate_test_activity_logs(INTEGER) CASCADE;
DROP FUNCTION IF EXISTS generate_test_order_items() CASCADE;
DROP FUNCTION IF EXISTS generate_test_orders(INTEGER) CASCADE;
DROP FUNCTION IF EXISTS generate_test_products(INTEGER) CASCADE;
DROP FUNCTION IF EXISTS generate_test_categories() CASCADE;
DROP FUNCTION IF EXISTS generate_test_users(INTEGER) CASCADE;
DROP FUNCTION IF EXISTS random_city() CASCADE;
DROP FUNCTION IF EXISTS random_last_name() CASCADE;
DROP FUNCTION IF EXISTS random_first_name() CASCADE;
DROP FUNCTION IF EXISTS random_email(TEXT) CASCADE;
DROP FUNCTION IF EXISTS cleanup_test_data() CASCADE;
DROP FUNCTION IF EXISTS quick_test_setup() CASCADE;

-- 3. Usuń wszystkie indeksy testowe (jeśli jakieś zostały)
DO $$ 
DECLARE
    r RECORD;
BEGIN
    FOR r IN (SELECT indexname FROM pg_indexes WHERE schemaname = 'public' AND indexname LIKE '%test%') 
    LOOP
        EXECUTE 'DROP INDEX IF EXISTS ' || r.indexname;
    END LOOP;
END $$;

-- 4. Potwierdzenie
SELECT 'Cleanup completed!' as status;




psql "sslmode=verify-ca \
      sslrootcert=/Users/radek/.postgresql/server-ca.pem \
      sslcert=/Users/radek/.postgresql/client-cert.pem \
      sslkey=/Users/radek/.postgresql/client-key.pem \
      hostaddr=34.32.113.115 \
      port=5432 \
      user=postgres \
      dbname=performance_test" -f load_generator.sql






SELECT quick_test();

-- ŚREDNI (5-10 min): 10k users, 5k products, 50k orders - POLECANY
SELECT medium_test();

-- DUŻY (30+ min): 50k users, 20k products, 200k orders
SELECT large_test();


----psql -h 34.32.113.115 -U postgres -d performance_test  


psql "sslmode=verify-ca \
      sslrootcert=/Users/radek/.postgresql/server-ca.pem \
      sslcert=/Users/radek/.postgresql/client-cert.pem \
      sslkey=/Users/radek/.postgresql/client-key.pem \
      hostaddr=34.32.113.115 \
      port=5432 \
      user=postgres \
      dbname=performance_test"




 SELECT
     schemaname,
     tablename,
     pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS total_size,
     pg_size_pretty(table_len) AS table_len,
     pg_size_pretty(tuple_len) AS tuple_len,
     pg_size_pretty(dead_tuple_len) AS dead_tuple_len,
     ROUND(dead_tuple_percent::numeric, 2) AS dead_tuple_pct,
     pg_size_pretty(free_space) AS free_space,
     ROUND(free_percent::numeric, 2) AS free_pct
 FROM (
     SELECT 
         schemaname,
         tablename,
         (pgstattuple(schemaname||'.'||tablename)).*
     FROM pg_tables
     WHERE schemaname = 'public'
     AND pg_total_relation_size(schemaname||'.'||tablename) > 10485760  only tables > 10MB
     LIMIT 10
 ) AS bloat_data
 ORDER BY dead_tuple_percent DESC;



psql --log-file="session_$(date +%Y%m%d_%H%M%S).log" \
     -f performance_test.sql \
     "sslmode=verify-ca \
      sslrootcert=/Users/radek/.postgresql/server-ca.pem \
      sslcert=/Users/radek/.postgresql/client-cert.pem \
      sslkey=/Users/radek/.postgresql/client-key.pem \
      hostaddr=34.32.113.115 \
      port=5432 \
      user=postgres \
      dbname=performance_test"


---------------------------------------------

./run_monitoring.sh


#!/bin/bash
LOG_FILE="session_$(date +%Y%m%d_%H%M%S).log"

psql -a -f performance_test.sql \
     "sslmode=verify-ca \
      sslrootcert=/Users/radek/.postgresql/server-ca.pem \
      sslcert=/Users/radek/.postgresql/client-cert.pem \
      sslkey=/Users/radek/.postgresql/client-key.pem \
      hostaddr=34.32.113.115 \
      port=5432 \
      user=postgres \
      dbname=performance_test" 2>&1 | tee "$LOG_FILE"

echo "Log saved to: $LOG_FILE"

----------------------------------------------







cat $(ls -t session_*.log | head -1)


Deadlocki i locki:
resource.type="cloudsql_database" AND (textPayload=~"deadlock" OR textPayload=~"lock")

Logi z ostatniej godziny:
resource.type="cloudsql_database" AND timestamp>="2025-10-07T18:00:00Z"

Tylko błędy:
resource.type="cloudsql_database" AND severity="ERROR"




Albo jeszcze lepiej (pokazuje dokładny czas):
resource.type="cloudsql_database" AND textPayload=~"duration: [0-9]+ ms  statement:"
resource.type="cloudsql_database"  AND textPayload=~"duration: [1-9][0-9]{3,} ms  statement:"

SHOW log_min_duration_statement;