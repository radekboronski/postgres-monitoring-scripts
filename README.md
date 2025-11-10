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

## What it analyzes

- Top 20 slowest queries
- Cache hit ratio
- Index usage vs sequential scans
- Active connections and locks
- Table and index bloat
- VACUUM statistics
- I/O and temp files
- Optimization recommendations

## Output

Logs are saved as: `session_YYYYMMDD_HHMMSS.log`

