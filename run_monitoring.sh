#!/bin/bash
LOG_FILE="session_$(date +%Y%m%d_%H%M%S).log"

psql -a -f performance_test.sql \
     "hostaddr=<host> \
      port=<port> \
      user=postgres \
      dbname=<db>" 2>&1 | tee "$LOG_FILE"

echo "Log saved to: $LOG_FILE"





#!/bin/bash
LOG_FILE="raporty/sunflower_session_$(date +%Y%m%d_%H%M%S).log"

export PGPASSWORD="qYh9z2PdKXRQQ6CDAqfa"

psql -a -f performance_test.sql \
     "host=localhost \
      port=5432 \
      user=monitoring_user \
      dbname=sunflower" 2>&1 | tee "$LOG_FILE"

echo "Log saved to: $LOG_FILE"

