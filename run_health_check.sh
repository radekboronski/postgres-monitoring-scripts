#!/bin/bash
mkdir -p raporty
LOG_FILE="raporty/health_check_$(date +%Y%m%d_%H%M%S).log"
export PGPASSWORD='Wj6G625^6Ea%cF'
psql -a -f pg_comprehensive_health_check.sql \
     "host=localhost \
      port=5432 \
      user=radoslawboronski \
      dbname=formunauts" 2>&1 | tee "$LOG_FILE"
echo "Log saved to: $LOG_FILE"
