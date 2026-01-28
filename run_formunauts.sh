#!/bin/bash
mkdir -p raporty
LOG_FILE="raporty/formunauts_session_$(date +%Y%m%d_%H%M%S).log"
export PGPASSWORD='Wj6G625^6Ea%cF'
psql -a -f formunauts_performance_test.sql \
     "host=localhost \
      port=5432 \
      user=radoslawboronski \
      dbname=formunauts" 2>&1 | tee "$LOG_FILE"
echo "Log saved to: $LOG_FILE"
