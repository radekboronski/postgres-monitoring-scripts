#!/bin/bash
HOST=
PORT=
USER=postgress
DBNAME=

LOG_FILE="parameter_analysis_$(date +%Y%m%d_%H%M%S).log"


psql -a -f parameter_analysis.sql \
  "host=$HOST \
   port=$PORT \
   user=$USER \
   dbname=$DBNAME" 2>&1 | tee "$LOG_FILE"

echo "Log saved to: $LOG_FILE"


LOG_FILE="constraint_analysis_$(date +%Y%m%d_%H%M%S).log"

psql -a -f constraint_analysis.sql \
  "host=$HOST \
   port=$PORT \
   user=$USER \
   dbname=$DBNAME" 2>&1 | tee "$LOG_FILE"

echo "Log saved to: $LOG_FILE"



LOG_FILE="bloat_analysis_$(date +%Y%m%d_%H%M%S).log"

psql -a -f bloat_analysis.sql \
  "host=$HOST \
   port=$PORT \
   user=$USER \
   dbname=$DBNAME" 2>&1 | tee "$LOG_FILE"

echo "Log saved to: $LOG_FILE"