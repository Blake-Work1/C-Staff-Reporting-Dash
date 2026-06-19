# Tricentis FP&A Reporting Modernization

**Owner:** Strategic Finance — Blake Buckley  
**Live dashboard:** https://blake-work1.github.io/C-Staff-Reporting-Dash/
**Last updated:** June 2026 · v1

---

## What this is

A modernized C-suite monthly reporting system that replaces a heavily manual, error-prone Excel workflow with a live, refreshable web application. The system pulls ACV bookings, ARR, GRR/NRR, customer metrics, headcount, and S&M efficiency data from Tricentis's Azure SQL data lake and delivers them as a consistent, validated reporting pack to C-staff and board audiences.

**The core problem it solves:** the previous process required several days of manual data collection, copy-pasting across Excel files, and hidden formula logic with no audit trail. One wrong paste could silently corrupt a board metric. This system makes every calculation explicit, auditable, and reproducible.

---

## What this is not

This is not a replacement for the ARR Balance Creation notebook or the Bookings & Renewals Flash file. Those remain the agreed-upon sources of truth for their respective metrics. This system reads from their outputs — it does not recompute them.

---

## Architecture

```
Data Sources
├── Bookings & Renewals Flash.xlsx      → ACV historical (locked, uploaded monthly)
├── sfdc_trf.opportunity_live           → ACV live (current open month, warehouse)
├── sfdc_trf.opportunity_nacv_live      → NACV / product-level ACV splits
├── arr_balances_master (Delta table)   → ARR walk (output of ARR Balance Creation)
├── workday_tri.employee_details_*      → Headcount
└── netsuite.transaction_line_live      → S&M expense

Processing Layer (Python)
├── flash_parser.py                     → Parses Flash file → standardized DataFrame
├── live_query.sql                      → T-SQL for current-month ACV from warehouse
├── lock_table.json                     → Controls which periods use flash vs live
└── merge_layer.py                      → Routes each period to correct source

Output
└── C-Staff Dashboard (Azure Static Web Apps)
    ├── ARR Momentum tab
    ├── ACV Bookings tab
    ├── Retention (GRR / NRR) tab
    └── Efficiency (S&M, Headcount) tab
```

---

## ACV pipeline — two-layer design

ACV data has two sources that are merged into a single unified dataset by period.

**Historical (locked months):** When your manager uploads the monthly Flash file, all periods covered by that file flip to `source = flash`. The Flash file is the source of truth for all prior months because it contains Finance-approved, FX-adjusted, manually-reviewed figures. Every new upload revises all prior history automatically.

**Live (current open month):** The current month reads directly from `sfdc_trf.opportunity_live` and `opportunity_nacv_live` in the Azure SQL data lake. The same locked monthly FX rates are applied via `sfdc_trf.dated_conversion_rate_live` so the live number is as close to the final Flash figure as possible. The known gap is FX rate timing and Finance overrides — these are resolved when the Flash file is uploaded at month close.

The `lock_table.json` file controls which source wins for each period. Uploading a new Flash file updates the lock table automatically.

---

## ARR pipeline

ARR calculations are **not** recomputed in this system. The ARR Balance Creation notebook (PySpark, Power BI) remains the authoritative calculation engine. Its output — the `arr_balances_master` Delta table partitioned by `balance_date` — is the read source for the dashboard.

When the ARR notebook runs at month close, it writes the new balance date partition. The dashboard reads the latest partition on the next refresh. No additional ARR logic exists in this codebase.

**Regression test UCIDs** (validate these after any ARR pipeline change):  
`10000222` · `10050201` · `10112949` · `10176361`

---

## Validation approach

Accuracy is paramount. Every metric has a validation layer before it reaches the dashboard.

| Metric | Validation method |
|---|---|
| ACV (historical) | Flash parser output vs Monthly Finance Metrics workbook — tolerance ≤0.1% |
| ACV (live) | Live query geo totals vs Flash file for most recent closed month |
| ARR | `arr_balances_master` total live ARR vs Post-May Tricentis Live ARR Details |
| GRR / NRR | UCID-level rolling 12-month values vs NRR GRR Values Reported USD tab |
| Headcount | `workday_tri` active count vs monthly HR report |

No metric goes to the dashboard until its validation check passes. The system is designed to fail loudly rather than silently publish wrong numbers.

---

## Repo structure

```
/
├── README.md                           → This file
├── index.html                          → C-staff dashboard (Azure Static Web Apps)
├── table_finder.html                   → Data lake table discovery tool
├── acv_pipeline/
│   ├── flash_parser.py                 → Flash file ingestion + standardization
│   ├── live_query.sql                  → T-SQL for live ACV from warehouse
│   ├── lock_table.json                 → Period → source mapping
│   └── merge_layer.py                  → Unified ACV DataFrame (coming soon)
├── docs/
│   ├── arr_logic.md                    → Seven-stage ARR pipeline documentation
│   ├── acv_field_map.md                → Flash file column index → SQL field mapping
│   └── validation_log.md               → Monthly validation results
└── .github/
    └── ISSUE_TEMPLATE/                 → Bug report and data discrepancy templates
```

---

## Monthly close workflow

1. **ARR notebook runs** — data engineering team runs ARR Balance Creation for the new `balance_date`. Dashboard auto-reads the new partition.
2. **Flash file uploaded** — upload the new `Bookings & Renewals Flash - [Month] FINAL.xlsx`. Lock table updates automatically. All prior months flip to flash source.
3. **Validation runs** — check the three validation queries in `docs/validation_log.md`. All gaps must be within tolerance before publishing.
4. **Dashboard refreshes** — navigate to the Azure Static Web App URL. Data is live.
5. **Writeup generated** — run the writeup generator against the refreshed data to produce the Word document for C-staff distribution.

---

## Key data sources (Azure SQL data lake)

| Schema | Key tables | Used for |
|---|---|---|
| `sfdc_trf` | `opportunity_live`, `opportunity_nacv_live`, `account_live`, `dated_conversion_rate_live` | ACV bookings, FX conversion |
| `sfdc_trf` | `sbqq_subscription_live`, `contract_live`, `contract_history_live` | ARR pipeline inputs |
| `mat` | `Finance_arr_live` | *Not used* — not FP&A agreed metric |
| `netsuite` | `transaction_line_live`, `department_live` | S&M expense |
| `workday_tri` | `employee_details_for_sales_unit_live` | Headcount |
| `sharepoint` | `Finance_Approved_ACV_Q12026_live`, `FinanceOpps_Overwrite_042026_live` | Finance overrides |
| `csv` | `Product_Mapping_live`, `Booking_Team_Mapping_live` | Dimension mappings |

Full table catalog: [Data Lake Table Finder](table_finder.html)

---

## Setup (first time)

**Prerequisites:** Python 3.10+, Azure Data Studio or pyodbc, access to Tricentis Azure SQL Server

```bash
# Clone the repo
git clone https://github.com/Blake-Work1/[repo-name].git
cd [repo-name]

# Install Python dependencies
pip install pandas openpyxl pyodbc sqlalchemy

# Test Flash parser
python acv_pipeline/flash_parser.py path/to/Bookings_Flash.xlsx

# Test SQL connection (replace with your server string)
# See docs/setup.md for connection string format
```

**Azure Static Web Apps deployment:** Any push to `main` triggers automatic deployment. No manual steps required after initial setup.

---

## Contributing

This project is maintained by Strategic Finance. If you find a data discrepancy, open an issue using the **Data Discrepancy** template — include the metric name, the value you see in the dashboard, and what the source file shows.

For code changes, open a pull request against `main`. All changes require validation results attached before merge.

---

*Tricentis Strategic Finance · FP&A Reporting Modernization · Confidential*
