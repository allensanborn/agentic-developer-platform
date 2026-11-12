#!/bin/sh
# Database roles. Passwords come from the environment (a Secret synced from Secrets
# Manager), never from this file.
set -eu
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d chinook \
  -v executor_password="$ERP_EXECUTOR_PASSWORD" -v reader_password="$ERP_READER_PASSWORD" <<'SQL'
-- Owns the fix functions and holds the only table write access. Nobody can log in as it.
CREATE ROLE fix_owner NOLOGIN;
GRANT USAGE ON SCHEMA public, detect, fix TO fix_owner;
GRANT SELECT ON ALL TABLES IN SCHEMA public, detect TO fix_owner;
GRANT UPDATE ON invoice, invoice_line TO fix_owner;
GRANT SELECT, INSERT ON fix.audit TO fix_owner;
ALTER FUNCTION fix.is_open(text, int) OWNER TO fix_owner;
ALTER FUNCTION fix.run(text, int, text, jsonb) OWNER TO fix_owner;
ALTER FUNCTION fix.dry_run(text, int, text, jsonb) OWNER TO fix_owner;
ALTER FUNCTION fix.commit(text, int, text, jsonb, text, text) OWNER TO fix_owner;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA fix FROM PUBLIC;

-- The executor: two functions, no tables.
CREATE ROLE erp_executor LOGIN PASSWORD :'executor_password';
GRANT USAGE ON SCHEMA fix TO erp_executor;
GRANT EXECUTE ON FUNCTION fix.dry_run(text, int, text, jsonb), fix.commit(text, int, text, jsonb, text, text) TO erp_executor;

-- The agent's tools: read everything, change nothing.
CREATE ROLE erp_reader LOGIN PASSWORD :'reader_password';
GRANT USAGE ON SCHEMA public, detect TO erp_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public, detect TO erp_reader;
ALTER ROLE erp_reader SET default_transaction_read_only = on;
SQL
