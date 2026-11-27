# MediGuard

MediGuard is a PostgreSQL-backed local pharmacy inventory, expiry-lock and FIFO checkout console. It includes a Flask API/UI, installable SQL scripts, reports, query-plan comparison, and transaction-safe QA checks.

## Requirements

- Python 3.10+
- PostgreSQL 14+
- A PostgreSQL login that owns the MediGuard tables and can create roles, functions, procedures, and indexes.

## Database setup

Run the scripts in this order using a database owner/superuser:

1. `01_master_tables.sql`
2. `03_expiry_triggers.sql`
3. `04_sales_tables.sql`
4. `03_fifo_checkout_procedures.sql`
5. `06_demo_seed.sql` (optional deterministic console data)
6. `04_reports_indexes_and_explain.sql`

For example, with `psql` installed and `DATABASE_URL` set:

```powershell
psql $env:DATABASE_URL -v ON_ERROR_STOP=1 -f .\01_master_tables.sql
psql $env:DATABASE_URL -v ON_ERROR_STOP=1 -f .\03_expiry_triggers.sql
psql $env:DATABASE_URL -v ON_ERROR_STOP=1 -f .\04_sales_tables.sql
psql $env:DATABASE_URL -v ON_ERROR_STOP=1 -f .\03_fifo_checkout_procedures.sql
psql $env:DATABASE_URL -v ON_ERROR_STOP=1 -f .\06_demo_seed.sql
psql $env:DATABASE_URL -v ON_ERROR_STOP=1 -f .\04_reports_indexes_and_explain.sql
```

`01_master_tables.sql` already defines sales tables to keep the full 3NF schema in one place; `04_sales_tables.sql` is an idempotent standalone sales-table migration for installations that apply the sale schema separately. Do not use the report script to install indexes before the master tables and trigger are present.

The role groups are `mediguard_hr_admin`, `mediguard_pharmacist`, and `mediguard_auditor`. FIFO checkout and expiry refresh use narrowly scoped `SECURITY DEFINER` procedures; pharmacists do not receive direct table-write grants. The console uses `SET LOCAL ROLE` for each request. Grant the appropriate group membership to the PostgreSQL login used by the app, for example:

```sql
GRANT mediguard_hr_admin, mediguard_pharmacist, mediguard_auditor TO mediguard_app;
```

The role selector is an educational role switcher, not user authentication. In a deployed service, authenticate users and grant only the database role appropriate to each user.

## Run the console

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r .\requirements.txt
$env:MEDIGUARD_DATABASE_URL = "postgresql://mediguard_app:kunal@localhost:5432/mediguard"
python .\app.py
```

Open <http://127.0.0.1:5000>. With no `MEDIGUARD_DATABASE_URL`, the console starts in **Demo mode** with sample data, simulated checkout/reports/query plans, and the six visual QA results. Demo activity is clearly labeled and does not execute SQL or modify a database. The sample inventory and sales reset when the server restarts.

To explicitly select a mode, set `MEDIGUARD_DEMO_MODE=1` for the demo or `MEDIGUARD_DEMO_MODE=0` with `MEDIGUARD_DATABASE_URL` set for live PostgreSQL. If the mode variable is omitted, the app uses demo mode when no database URL is configured and live mode when a URL is configured.

## QA and reports

- `05_qa_and_verification.sql` runs fixture checks inside a transaction and ends with `ROLLBACK`; it does not truncate or retain pharmacy data.
- The UI QA runner executes TC-01 through TC-06 in a temporary transaction, then rolls back all fixture and sale rows.
- Reports A/B/C run against the live database. The execution-plan view compares a sequential baseline (index paths disabled) with an index-path demonstration (sequential scans disabled); compare it with normal production plans before drawing performance conclusions.
