# PostgreSQL Performance Monitoring

Performance monitoring script for PostgreSQL/Aurora.

## Setup

### 1. Save files in the same directory

Make sure both files are in the same location:
- `performance_test.sql`
- `run_monitoring.sh`

### 2. Configure passwordless authentication

**Option 1: ~/.pgpass file**
```bash
cat > ~/.pgpass << 'EOF'
<aurora-host>:5432:<db_name>:postgres:<password>
EOF

chmod 600 ~/.pgpass
```

**Option 2: AWS IAM (for Aurora)**
```bash
export PGPASSWORD=$(aws rds generate-db-auth-token \
    --hostname <aurora-host> \
    --port 5432 \
    --username postgres \
    --region us-east-1)
```

### 3. Edit run_monitoring.sh

Update with your connection details:
```bash
psql -a -f performance_test.sql \
     "hostaddr=<your-host> \
      port=5432 \
      user=postgres \
      dbname=<your-database>" 2>&1 | tee "$LOG_FILE"
```

### 3. Run

```bash
chmod +x run_monitoring.sh
./run_monitoring.sh
```

------------- Constraints Parameters Bloat ------------------------

### 4. Refresh repo

```bash
git pull origin main
```

Above should download 4 files from repo

```bash
bloat_analysis.sql
constraint_analysis.sql
parameter_analysis.sql
const_bloat_param_analysis.sh
```

### 4. Edit const_bloat_param_analysis.sh

```bash
#!/bin/bash
HOST=
PORT=
USER=postgress
DBNAME=
```

### 4. Run

```bash
chmod +x const_bloat_param_analysis.sh
./const_bloat_param_analysis.sh
```



## What it analyzes

- Top 20 slowest queries
- Cache hit ratio
- Index usage vs sequential scans
- Active connections and locks
- Table and index bloat
- VACUUM statistics
- I/O and temp files
- Optimization recommendations
- Bloated tables
- Connection parameters
- Constraints issues

## Output

Logs are saved as: `session_YYYYMMDD_HHMMSS.log`
Log saved to: parameter_YYYYMMDD_HHMMSS.log
Log saved to: constraint_analysis_YYYYMMDD_HHMMSS.log
Log saved to: bloat_analysis_YYYYMMDD_HHMMSS.log
