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
