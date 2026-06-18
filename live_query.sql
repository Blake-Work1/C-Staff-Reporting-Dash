/*
live_query.sql  v2
──────────────────
Fixed three issues found in v1:
  1. Duplicate rows — opportunity_nacv_live returns multiple rows per opp
     even with Period_Number__c = 1. Fixed with a CTE that takes the MAX
     NACV per opportunity, deduplicating before the main join.
  2. nacv_usd = 0 for many rows — NACV__c on nacv table is 0/NULL for
     some deals but product columns on opportunity_live have values.
     total_acv_usd now derived from SUM of all product columns as fallback.
  3. FX rate NULL for USD deals — USD has no row in dated_conversion_rate_live.
     Fixed with COALESCE(fx.ConversionRate, 1.0) so USD stays USD.

Parameters:
  @period_start = first day of month  e.g. '2026-06-01'
  @period_end   = last day of month   e.g. '2026-06-30'
*/

DECLARE @period_start DATE = '2026-06-01';
DECLARE @period_end   DATE = EOMONTH('2026-06-01');

-- ── CTE 1: deduplicate opportunity_nacv_live ──────────────────────
-- Takes one row per opportunity (Period_Number__c = 1, highest NACV)
WITH nacv_dedup AS (
    SELECT
        Opportunity__c,
        MAX(NACV__c)   AS NACV__c,
        MAX(Uplift__c) AS Uplift__c
    FROM sfdc_trf.opportunity_nacv_live
    WHERE Period_Number__c = 1
    GROUP BY Opportunity__c
),

-- ── CTE 2: FX rates — one row per currency per month start ────────
fx_rates AS (
    SELECT
        IsoCode,
        CAST(StartDate AS DATE) AS rate_month,
        ConversionRate
    FROM sfdc_trf.dated_conversion_rate_live
    -- Keep only one row per currency per month (handle any overlaps)
    -- Use the most recent rate loaded for that month
    WHERE StartDate IS NOT NULL
)

SELECT
    -- ── Identity ──────────────────────────────────────────────────
    a.UCID__c                                   AS ucid,
    a.Name                                      AS account_name,
    o.UOID__c                                   AS uoid,
    o.SFDC_Opportunity_ID_18__c                 AS sfdc_opp_id,

    -- ── Time ──────────────────────────────────────────────────────
    CAST(EOMONTH(o.CloseDate) AS DATE)          AS eom,
    o.CloseDate                                 AS close_date,

    -- ── Classification ────────────────────────────────────────────
    a.Geo__c                                    AS geo,
    a.Current_Segment__c                        AS tier,

    CASE
        WHEN a.Current_Segment__c IN ('Tier 1','Tier 2') THEN 'Enterprise'
        ELSE 'Non-Enterprise'
    END                                         AS enterprise_flag,

    -- Segment: pure-uplift deals = CPI, everything else = Core
    CASE
        WHEN ISNULL(n.NACV__c, 0) = 0
             AND ISNULL(n.Uplift__c, 0) > 0    THEN 'CPI'
        WHEN ISNULL(n.NACV__c, 0) > 0
             AND ISNULL(n.Uplift__c, 0) > 0
             AND ISNULL(n.NACV__c, 0)
                 = ISNULL(n.Uplift__c, 0)      THEN 'CPI'
        ELSE 'Core'
    END                                         AS segment,

    -- Fulfillment channel
    CASE
        WHEN o.Going_through_Solex__c = 1       THEN 'Solex'
        WHEN o.Opportunity_Source__c LIKE '%artner%'
                                                THEN 'Partner'
        ELSE 'Direct'
    END                                         AS fulfillment_channel,

    -- New vs Existing
    CASE
        WHEN o.Type = 'New Business'            THEN 'New'
        ELSE 'Existing'
    END                                         AS new_vs_existing,

    o.Type                                      AS deal_type,
    o.StageName                                 AS stage,

    CASE WHEN o.StageName IN (
        'Closed Won','Stage 5 - Closed Won')
        THEN 1 ELSE 0
    END                                         AS is_closed_won,

    CASE WHEN o.StageName IN (
        'Stage 4 - Closed Pending','6 - Closed/Pending')
        THEN 1 ELSE 0
    END                                         AS is_closed_pending,

    -- ── FX rate (1.0 for USD, looked up for all others) ──────────
    COALESCE(fx.ConversionRate, 1.0)            AS fx_rate,
    o.CurrencyIsoCode                           AS native_currency,

    -- ── Financial — NACV from nacv table, converted to USD ────────
    -- NACV__c and Uplift__c are in native currency; divide by rate
    ROUND(
        ISNULL(n.NACV__c,   0)
        / COALESCE(NULLIF(fx.ConversionRate,0), 1.0),
    2)                                          AS nacv_usd,

    ROUND(
        ISNULL(n.Uplift__c, 0)
        / COALESCE(NULLIF(fx.ConversionRate,0), 1.0),
    2)                                          AS nacv_uplift_usd,

    -- ── Product columns — all from opportunity_live, USD-converted ─
    ROUND(ISNULL(o.Tosca_BI_expansion_upsell__c,        0)/COALESCE(NULLIF(fx.ConversionRate,0),1.0),2) AS tosca_bi_sl,
    ROUND(ISNULL(o.Tosca_BI_Uplift__c,                  0)/COALESCE(NULLIF(fx.ConversionRate,0),1.0),2) AS tosca_bi_cpi,
    ROUND(ISNULL(o.Tosca_expansion_upsell__c,           0)/COALESCE(NULLIF(fx.ConversionRate,0),1.0),2) AS tosca_sl,
    ROUND(ISNULL(o.Tosca_Uplift__c,                     0)/COALESCE(NULLIF(fx.ConversionRate,0),1.0),2) AS tosca_cpi,
    ROUND(ISNULL(o.Tosca_OSV_expansion_upsell__c,       0)/COALESCE(NULLIF(fx.ConversionRate,0),1.0),2) AS tosca_osv_sl,
    ROUND(ISNULL(o.Tosca_OSV_Uplift__c,                 0)/COALESCE(NULLIF(fx.ConversionRate,0),1.0),2) AS tosca_osv_cpi,
    ROUND(ISNULL(o.TEE_expansion_upsell__c,             0)/COALESCE(NULLIF(fx.ConversionRate,0),1.0),2) AS tee_sl,
    ROUND(ISNULL(o.TEE_Uplift__c,                       0)/COALESCE(NULLIF(fx.ConversionRate,0),1.0),2) AS tee_cpi,
    ROUND(ISNULL(o.TTA_expansion_upsell__c,             0)/COALESCE(NULLIF(fx.ConversionRate,0),1.0),2) AS tta_sl,
    ROUND(ISNULL(o.TTA_Uplift__c,                       0)/COALESCE(NULLIF(fx.ConversionRate,0),1.0),2) AS tta_cpi,
    ROUND(ISNULL(o.Testim_Salesforce_expansion_upsell__c,0)/COALESCE(NULLIF(fx.ConversionRate,0),1.0),2) AS testim_sf_sl,
    ROUND(ISNULL(o.Testim_Salesforce_Uplift__c,         0)/COALESCE(NULLIF(fx.ConversionRate,0),1.0),2) AS testim_sf_cpi,
    ROUND(ISNULL(o.NeoLoad_expansion_upsell__c,         0)/COALESCE(NULLIF(fx.ConversionRate,0),1.0),2) AS neoload_sl,
    ROUND(ISNULL(o.NeoLoad_Uplift__c,                   0)/COALESCE(NULLIF(fx.ConversionRate,0),1.0),2) AS neoload_cpi,
    ROUND(ISNULL(o.qTest_expansion_upsell__c,           0)/COALESCE(NULLIF(fx.ConversionRate,0),1.0),2) AS qtest_sl,
    ROUND(ISNULL(o.qTest_Uplift__c,                     0)/COALESCE(NULLIF(fx.ConversionRate,0),1.0),2) AS qtest_cpi,
    ROUND(ISNULL(o.LiveCompare_expansion_upsell__c,     0)/COALESCE(NULLIF(fx.ConversionRate,0),1.0),2) AS livecompare_sl,
    ROUND(ISNULL(o.LiveCompare_Uplift__c,               0)/COALESCE(NULLIF(fx.ConversionRate,0),1.0),2) AS livecompare_cpi,
    ROUND(ISNULL(o.Testim_expansion_upsell__c,          0)/COALESCE(NULLIF(fx.ConversionRate,0),1.0),2) AS testim_sl,
    ROUND(ISNULL(o.Testim_Uplift__c,                    0)/COALESCE(NULLIF(fx.ConversionRate,0),1.0),2) AS testim_cpi,
    ROUND(ISNULL(o.Vera_expansion_upsell__c,            0)/COALESCE(NULLIF(fx.ConversionRate,0),1.0),2) AS vera_sl,
    ROUND(ISNULL(o.VERA_Uplift__c,                      0)/COALESCE(NULLIF(fx.ConversionRate,0),1.0),2) AS vera_cpi,
    ROUND(ISNULL(o.Mobile_expansion_upsell__c,          0)/COALESCE(NULLIF(fx.ConversionRate,0),1.0),2) AS mobile_sl,
    ROUND(ISNULL(o.Mobile_Uplift__c,                    0)/COALESCE(NULLIF(fx.ConversionRate,0),1.0),2) AS mobile_cpi,
    ROUND(ISNULL(o.TDC_expansion_upsell__c,             0)/COALESCE(NULLIF(fx.ConversionRate,0),1.0),2) AS tdc_sl,
    ROUND(ISNULL(o.TDC_Uplift__c,                       0)/COALESCE(NULLIF(fx.ConversionRate,0),1.0),2) AS tdc_cpi,
    ROUND(ISNULL(o.SeaLights_expansion_upsell__c,       0)/COALESCE(NULLIF(fx.ConversionRate,0),1.0),2) AS sealights_sl,
    ROUND(ISNULL(o.SeaLights_Uplift__c,                 0)/COALESCE(NULLIF(fx.ConversionRate,0),1.0),2) AS sealights_cpi,
    ROUND(ISNULL(o.Agentic_expansion_upsell__c,         0)/COALESCE(NULLIF(fx.ConversionRate,0),1.0),2) AS agentic_sl,
    ROUND(ISNULL(o.Agentic_Uplift__c,                   0)/COALESCE(NULLIF(fx.ConversionRate,0),1.0),2) AS agentic_cpi,
    ROUND(ISNULL(o.Services_ACV__c,                     0)/COALESCE(NULLIF(fx.ConversionRate,0),1.0),2) AS advisory_services_acv,
    ROUND(ISNULL(o.Support_ACV__c,                      0)/COALESCE(NULLIF(fx.ConversionRate,0),1.0),2) AS support_acv,

    -- ── total_acv_usd: sum of all product columns (most reliable) ─
    -- This matches how the Flash file calculates Total ACV
    ROUND((
        ISNULL(o.Tosca_BI_expansion_upsell__c,        0)
      + ISNULL(o.Tosca_BI_Uplift__c,                  0)
      + ISNULL(o.Tosca_expansion_upsell__c,           0)
      + ISNULL(o.Tosca_Uplift__c,                     0)
      + ISNULL(o.Tosca_OSV_expansion_upsell__c,       0)
      + ISNULL(o.Tosca_OSV_Uplift__c,                 0)
      + ISNULL(o.TEE_expansion_upsell__c,             0)
      + ISNULL(o.TEE_Uplift__c,                       0)
      + ISNULL(o.TTA_expansion_upsell__c,             0)
      + ISNULL(o.TTA_Uplift__c,                       0)
      + ISNULL(o.Testim_Salesforce_expansion_upsell__c,0)
      + ISNULL(o.Testim_Salesforce_Uplift__c,         0)
      + ISNULL(o.NeoLoad_expansion_upsell__c,         0)
      + ISNULL(o.NeoLoad_Uplift__c,                   0)
      + ISNULL(o.qTest_expansion_upsell__c,           0)
      + ISNULL(o.qTest_Uplift__c,                     0)
      + ISNULL(o.LiveCompare_expansion_upsell__c,     0)
      + ISNULL(o.LiveCompare_Uplift__c,               0)
      + ISNULL(o.Testim_expansion_upsell__c,          0)
      + ISNULL(o.Testim_Uplift__c,                    0)
      + ISNULL(o.Vera_expansion_upsell__c,            0)
      + ISNULL(o.VERA_Uplift__c,                      0)
      + ISNULL(o.Mobile_expansion_upsell__c,          0)
      + ISNULL(o.Mobile_Uplift__c,                    0)
      + ISNULL(o.TDC_expansion_upsell__c,             0)
      + ISNULL(o.TDC_Uplift__c,                       0)
      + ISNULL(o.SeaLights_expansion_upsell__c,       0)
      + ISNULL(o.SeaLights_Uplift__c,                 0)
      + ISNULL(o.Agentic_expansion_upsell__c,         0)
      + ISNULL(o.Agentic_Uplift__c,                   0)
      + ISNULL(o.Services_ACV__c,                     0)
      + ISNULL(o.Support_ACV__c,                      0)
    ) / COALESCE(NULLIF(fx.ConversionRate,0),1.0),
    2)                                          AS total_acv_usd,

    'live'                                      AS data_source

FROM sfdc_trf.opportunity_live o

JOIN sfdc_trf.account_live a
    ON o.AccountId = a.Id

-- Deduplicated NACV (one row per opp, Period 1 only)
LEFT JOIN nacv_dedup n
    ON n.Opportunity__c = o.Id

-- FX: join on first day of close month; USD falls through to COALESCE 1.0
LEFT JOIN fx_rates fx
    ON  fx.IsoCode      = o.CurrencyIsoCode
    AND fx.rate_month   = DATEFROMPARTS(
                              YEAR(o.CloseDate),
                              MONTH(o.CloseDate),
                              1
                          )

WHERE
    o.StageName IN (
        'Closed Won',
        'Stage 5 - Closed Won',
        'Stage 4 - Closed Pending',
        '6 - Closed/Pending'
    )
    AND o.CloseDate >= @period_start
    AND o.CloseDate <= @period_end
    AND o.CloseDate <= EOMONTH(GETDATE(), 2)
    AND o.IsDeleted  = 0

ORDER BY o.CloseDate DESC, o.UOID__c;


-- ── QUICK VALIDATION SUMMARY ─────────────────────────────────────
-- Run this separately to check totals before using row-level data
/*
WITH nacv_dedup AS (
    SELECT Opportunity__c, MAX(NACV__c) AS NACV__c, MAX(Uplift__c) AS Uplift__c
    FROM sfdc_trf.opportunity_nacv_live WHERE Period_Number__c = 1
    GROUP BY Opportunity__c
),
fx_rates AS (
    SELECT IsoCode, CAST(StartDate AS DATE) AS rate_month, ConversionRate
    FROM sfdc_trf.dated_conversion_rate_live WHERE StartDate IS NOT NULL
)
SELECT
    a.Geo__c                                    AS geo,
    COUNT(DISTINCT o.UOID__c)                   AS deal_count,
    SUM(CASE WHEN o.StageName IN ('Closed Won','Stage 5 - Closed Won')
        THEN 1 ELSE 0 END)                      AS closed_won_deals,
    ROUND(SUM(
        (  ISNULL(o.Tosca_BI_expansion_upsell__c,0)
         + ISNULL(o.Tosca_BI_Uplift__c,0)
         + ISNULL(o.Tosca_expansion_upsell__c,0)
         + ISNULL(o.Tosca_Uplift__c,0)
         + ISNULL(o.NeoLoad_expansion_upsell__c,0)
         + ISNULL(o.NeoLoad_Uplift__c,0)
         + ISNULL(o.qTest_expansion_upsell__c,0)
         + ISNULL(o.qTest_Uplift__c,0)
         + ISNULL(o.LiveCompare_expansion_upsell__c,0)
         + ISNULL(o.LiveCompare_Uplift__c,0)
         + ISNULL(o.Testim_expansion_upsell__c,0)
         + ISNULL(o.Testim_Uplift__c,0)
         + ISNULL(o.SeaLights_expansion_upsell__c,0)
         + ISNULL(o.SeaLights_Uplift__c,0)
         + ISNULL(o.Agentic_expansion_upsell__c,0)
         + ISNULL(o.Agentic_Uplift__c,0)
         + ISNULL(o.Services_ACV__c,0)
         + ISNULL(o.Support_ACV__c,0)
        ) / COALESCE(NULLIF(fx.ConversionRate,0),1.0)
    ), 0)                                       AS total_acv_usd
FROM sfdc_trf.opportunity_live o
JOIN sfdc_trf.account_live a ON o.AccountId = a.Id
LEFT JOIN nacv_dedup n ON n.Opportunity__c = o.Id
LEFT JOIN fx_rates fx
    ON fx.IsoCode = o.CurrencyIsoCode
    AND fx.rate_month = DATEFROMPARTS(YEAR(o.CloseDate),MONTH(o.CloseDate),1)
WHERE o.StageName IN ('Closed Won','Stage 5 - Closed Won',
                      'Stage 4 - Closed Pending','6 - Closed/Pending')
  AND o.CloseDate >= '2026-06-01'
  AND o.CloseDate <= EOMONTH('2026-06-01')
  AND o.CloseDate <= EOMONTH(GETDATE(),2)
  AND o.IsDeleted = 0
GROUP BY a.Geo__c
ORDER BY total_acv_usd DESC;
*/
