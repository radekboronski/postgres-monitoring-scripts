#!/bin/bash
LOG_FILE="session_$(date +%Y%m%d_%H%M%S).log"

psql -a -f performance_test.sql \
     "hostaddr=<host> \
      port=<port> \
      user=postgres \
      dbname=<db>" 2>&1 | tee "$LOG_FILE"

echo "Log saved to: $LOG_FILE"



