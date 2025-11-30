#!/bin/bash
LOG_FILE="pg_diagnostic_queries_$(date +%Y%m%d_%H%M%S).log"

psql -a -f pg_diagnostic_queries.sql \
     "host=localhost \
      port=5433 \
      user=test_user \
      dbname=terrogence" 2>&1 | tee "$LOG_FILE"

echo "Log saved to: $LOG_FILE"
