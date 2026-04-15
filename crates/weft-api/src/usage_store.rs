//! Usage event persistence for cost tracking.
//!
//! This module writes usage events to the `usage_events` table and provides
//! daily aggregation into `usage_daily`. All cost tracking data lives here
//! (open source, works in both local and cloud mode).
//!
//! ## SCHEMA SYNC WARNING
//!
//! The `usage_events` and `usage_daily` table schemas are defined in:
//!   - `weavemind/init-db/01-init.sql` (cloud, source of truth)
//!   - `init-db.sql` (local dev, should match)

use sqlx::PgPool;

/// Default base cost per project execution if tier lookup fails.
/// $0.001 = 1000 runs per dollar. Tiers can override this.
const DEFAULT_EXECUTION_BASE_COST: f64 = 0.001;


/// Look up the margin multiplier for a user.
/// Priority: subscription custom_margin > tier margin > 1.6 (free tier default).
/// Panics on DB errors or misconfigured enterprise users.
async fn get_user_margin(pool: &PgPool, user_id: &str) -> f64 {
    // Check for active subscription first (authoritative source)
    let sub: Option<(Option<f64>, String)> = sqlx::query_as(
        "SELECT s.custom_margin, s.tier FROM subscriptions s WHERE s.user_id = $1 AND s.status IN ('active', 'trialing')",
    )
    .bind(user_id)
    .fetch_optional(pool)
    .await
    .expect(&format!("DB error looking up subscription for user {}", user_id));

    if let Some((custom_margin, tier)) = sub {
        // Enterprise: must have custom_margin
        if let Some(margin) = custom_margin {
            return margin;
        }
        if tier == "enterprise" {
            panic!(
                "Enterprise subscription for user {} has no custom_margin set. This is a configuration error.",
                user_id
            );
        }
        // Starter/Builder: look up margin from pricing_tiers using the SUBSCRIPTION tier (not user_credits)
        let tier_margin: Option<(f64,)> = sqlx::query_as(
            "SELECT margin FROM pricing_tiers WHERE tier = $1",
        )
        .bind(&tier)
        .fetch_optional(pool)
        .await
        .expect(&format!("DB error looking up pricing tier {} for user {}", tier, user_id));

        return tier_margin.map(|(m,)| m).unwrap_or_else(|| {
            panic!("Pricing tier '{}' not found in pricing_tiers table", tier);
        });
    }

    // No subscription: use user_credits tier
    let result: Option<(f64, String)> = sqlx::query_as(
        r#"
        SELECT pt.margin, uc.tier
        FROM user_credits uc
        JOIN pricing_tiers pt ON pt.tier = uc.tier
        WHERE uc.user_id = $1
        "#,
    )
    .bind(user_id)
    .fetch_optional(pool)
    .await
    .expect(&format!("DB error looking up user_credits for user {}", user_id));

    match result {
        Some((margin, tier)) => {
            if tier == "enterprise" && margin == 0.0 {
                panic!(
                    "Enterprise user {} has tier=enterprise in user_credits but no subscription. Create one in the admin panel.",
                    user_id
                );
            }
            margin
        }
        None => 1.6, // No user_credits row yet, default to free tier (60% margin)
    }
}

/// Record a service usage event (LLM calls, STT, TTS, etc.).
/// Computes billed_usd at recording time: cost_usd * margin for platform, 0 for BYOK.
#[allow(non_snake_case)]
pub async fn record_service_cost(
    pool: &PgPool,
    userId: &str,
    eventType: &str,
    subtype: Option<&str>,
    projectId: Option<&str>,
    executionId: Option<&str>,
    nodeId: Option<&str>,
    model: Option<&str>,
    promptTokens: Option<i32>,
    completionTokens: Option<i32>,
    costUsd: f64,
    isByok: bool,
    metadata: Option<&serde_json::Value>,
) -> Result<(), sqlx::Error> {
    let billed_usd = if isByok {
        0.0
    } else {
        let margin = get_user_margin(pool, userId).await;
        costUsd * margin
    };

    let mut tx = pool.begin().await?;

    sqlx::query(
        r#"
        INSERT INTO usage_events
            (user_id, event_type, subtype, project_id, execution_id, node_id, model,
             prompt_tokens, completion_tokens, cost_usd, billed_usd, is_byok, metadata)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
        "#,
    )
    .bind(userId)
    .bind(eventType)
    .bind(subtype)
    .bind(projectId)
    .bind(executionId)
    .bind(nodeId)
    .bind(model)
    .bind(promptTokens.unwrap_or(0))
    .bind(completionTokens.unwrap_or(0))
    .bind(costUsd)
    .bind(billed_usd)
    .bind(isByok)
    .bind(metadata)
    .execute(&mut *tx)
    .await?;

    // Deduct billed amount from user's credit balance (same transaction)
    if billed_usd > 0.0 {
        let ref_id = executionId.or(projectId).unwrap_or("");
        sqlx::query(
            r#"
            WITH updated AS (
                UPDATE user_credits
                SET balance_usd = balance_usd - $2, updated_at = NOW()
                WHERE user_id = $1
                RETURNING balance_usd
            )
            INSERT INTO credit_transactions (user_id, amount_usd, reason, reference_id, balance_after)
            SELECT $1, -$2, $3, $4, balance_usd FROM updated
            "#,
        )
        .bind(userId)
        .bind(billed_usd)
        .bind(eventType)
        .bind(ref_id)
        .execute(&mut *tx)
        .await?;
    }

    tx.commit().await?;
    Ok(())
}

/// Get execution base cost for a user.
/// Priority: subscription custom_execution_base_cost > tier execution_base_cost > default.
/// Panics if an enterprise user has no custom_execution_base_cost set.
async fn get_execution_base_cost(pool: &PgPool, user_id: &str) -> f64 {
    // Check subscription custom override first
    let sub: Option<(Option<f64>, String)> = sqlx::query_as(
        "SELECT custom_execution_base_cost, tier FROM subscriptions WHERE user_id = $1 AND status IN ('active', 'trialing')",
    )
    .bind(user_id)
    .fetch_optional(pool)
    .await
    .expect(&format!("DB error looking up subscription execution cost for user {}", user_id));

    if let Some((custom_cost, tier)) = sub {
        if let Some(cost) = custom_cost {
            return cost;
        }
        if tier == "enterprise" {
            panic!(
                "Enterprise subscription for user {} has no custom_execution_base_cost set.",
                user_id
            );
        }
        // Use subscription tier to look up execution_base_cost from pricing_tiers
        let tier_cost: Option<(f64,)> = sqlx::query_as(
            "SELECT execution_base_cost FROM pricing_tiers WHERE tier = $1",
        )
        .bind(&tier)
        .fetch_optional(pool)
        .await
        .expect(&format!("DB error looking up execution cost for tier {}", tier));

        return tier_cost.map(|(c,)| c).unwrap_or_else(|| {
            panic!("Pricing tier '{}' not found in pricing_tiers table", tier);
        });
    }

    // No subscription: use user_credits tier
    let tier_result: Option<(f64, String)> = sqlx::query_as(
        r#"
        SELECT pt.execution_base_cost, uc.tier
        FROM user_credits uc
        JOIN pricing_tiers pt ON pt.tier = uc.tier
        WHERE uc.user_id = $1
        "#,
    )
    .bind(user_id)
    .fetch_optional(pool)
    .await
    .expect(&format!("DB error looking up user_credits execution cost for user {}", user_id));

    match tier_result {
        Some((cost, tier)) => {
            if tier == "enterprise" && cost == 0.0 {
                panic!(
                    "Enterprise user {} has tier=enterprise but no subscription.",
                    user_id
                );
            }
            cost
        }
        None => DEFAULT_EXECUTION_BASE_COST,
    }
}

/// Record a project execution event.
#[allow(non_snake_case)]
pub async fn record_execution(
    pool: &PgPool,
    userId: &str,
    projectId: &str,
    executionId: &str,
) -> Result<(), sqlx::Error> {
    // execution_base_cost in pricing_tiers is the final billed price, not a raw cost.
    // No margin multiplication: the tier already defines what the user pays.
    let billed_usd = get_execution_base_cost(pool, userId).await;
    let base_cost = billed_usd;

    let mut tx = pool.begin().await?;

    sqlx::query(
        r#"
        INSERT INTO usage_events
            (user_id, event_type, project_id, execution_id, cost_usd, billed_usd)
        VALUES ($1, 'execution', $2, $3, $4, $5)
        "#,
    )
    .bind(userId)
    .bind(projectId)
    .bind(executionId)
    .bind(base_cost)
    .bind(billed_usd)
    .execute(&mut *tx)
    .await?;

    if billed_usd > 0.0 {
        sqlx::query(
            r#"
            WITH updated AS (
                UPDATE user_credits
                SET balance_usd = balance_usd - $2, updated_at = NOW()
                WHERE user_id = $1
                RETURNING balance_usd
            )
            INSERT INTO credit_transactions (user_id, amount_usd, reason, reference_id, balance_after)
            SELECT $1, -$2, $3, $4, balance_usd FROM updated
            "#,
        )
        .bind(userId)
        .bind(billed_usd)
        .bind("execution")
        .bind(executionId)
        .execute(&mut *tx)
        .await?;
    }

    tx.commit().await?;
    Ok(())
}

/// Record a daily infrastructure cost snapshot.
///
/// Requires `metadata` with `snapshotDate` and `namespace` fields for deduplication.
/// This prevents duplicate billing records when the billing task runs multiple times
/// for the same day (e.g., after server restart).
#[allow(non_snake_case)]
pub async fn record_infra_daily(
    pool: &PgPool,
    userId: &str,
    costUsd: f64,
    metadata: Option<&serde_json::Value>,
) -> Result<(), sqlx::Error> {
    let snapshot_date = metadata
        .and_then(|m| m.get("snapshotDate"))
        .and_then(|v| v.as_str())
        .ok_or_else(|| sqlx::Error::Protocol(
            "infra_daily requires 'snapshotDate' in metadata".into()
        ))?;
    
    let namespace = metadata
        .and_then(|m| m.get("namespace"))
        .and_then(|v| v.as_str())
        .ok_or_else(|| sqlx::Error::Protocol(
            "infra_daily requires 'namespace' in metadata".into()
        ))?;

    let margin = get_user_margin(pool, userId).await;
    let billed_usd = costUsd * margin;

    // Conditional insert: only if this (user, date, namespace) hasn't been recorded yet.
    // Returns the number of rows inserted (0 or 1).
    let mut tx = pool.begin().await?;

    let result = sqlx::query(
        r#"
        INSERT INTO usage_events
            (user_id, event_type, cost_usd, billed_usd, metadata)
        SELECT $1, 'infra_daily', $2, $6, $3
        WHERE NOT EXISTS (
            SELECT 1
            FROM usage_events
            WHERE user_id = $1
              AND event_type = 'infra_daily'
              AND metadata->>'snapshotDate' = $4
              AND metadata->>'namespace' = $5
        )
        "#,
    )
    .bind(userId)
    .bind(costUsd)
    .bind(metadata)
    .bind(snapshot_date)
    .bind(namespace)
    .bind(billed_usd)
    .execute(&mut *tx)
    .await?;

    // Only deduct if the event was actually inserted (not a duplicate)
    if result.rows_affected() > 0 && billed_usd > 0.0 {
        let ref_id = format!("infra:{}:{}", namespace, snapshot_date);
        sqlx::query(
            r#"
            WITH updated AS (
                UPDATE user_credits
                SET balance_usd = balance_usd - $2, updated_at = NOW()
                WHERE user_id = $1
                RETURNING balance_usd
            )
            INSERT INTO credit_transactions (user_id, amount_usd, reason, reference_id, balance_after)
            SELECT $1, -$2, $3, $4, balance_usd FROM updated
            "#,
        )
        .bind(userId)
        .bind(billed_usd)
        .bind("infra_daily")
        .bind(&ref_id)
        .execute(&mut *tx)
        .await?;
    }

    tx.commit().await?;
    Ok(())
}

/// Aggregate usage_events into usage_daily for a specific date.
/// Uses UPSERT so it can be called multiple times safely (idempotent).
pub async fn aggregate_daily(
    pool: &PgPool,
    date: chrono::NaiveDate,
) -> Result<u64, sqlx::Error> {
    let result = sqlx::query(
        r#"
        INSERT INTO usage_daily
            (user_id, date,
             service_cost_usd, service_billed_usd, service_requests,
             tangle_cost_usd, tangle_billed_usd, tangle_requests,
             execution_count, execution_billed_usd,
             infra_cost_usd, infra_billed_usd, last_aggregated_at)
        SELECT
            user_id,
            $1 AS date,
            COALESCE(SUM(CASE WHEN event_type = 'service' THEN cost_usd ELSE 0 END), 0) AS service_cost_usd,
            COALESCE(SUM(CASE WHEN event_type = 'service' THEN billed_usd ELSE 0 END), 0) AS service_billed_usd,
            COALESCE(SUM(CASE WHEN event_type = 'service' THEN 1 ELSE 0 END), 0)::INTEGER AS service_requests,
            COALESCE(SUM(CASE WHEN event_type = 'tangle' THEN cost_usd ELSE 0 END), 0) AS tangle_cost_usd,
            COALESCE(SUM(CASE WHEN event_type = 'tangle' THEN billed_usd ELSE 0 END), 0) AS tangle_billed_usd,
            COALESCE(SUM(CASE WHEN event_type = 'tangle' THEN 1 ELSE 0 END), 0)::INTEGER AS tangle_requests,
            COALESCE(SUM(CASE WHEN event_type = 'execution' THEN 1 ELSE 0 END), 0)::INTEGER AS execution_count,
            COALESCE(SUM(CASE WHEN event_type = 'execution' THEN billed_usd ELSE 0 END), 0) AS execution_billed_usd,
            COALESCE(SUM(CASE WHEN event_type = 'infra_daily' THEN cost_usd ELSE 0 END), 0) AS infra_cost_usd,
            COALESCE(SUM(CASE WHEN event_type = 'infra_daily' THEN billed_usd ELSE 0 END), 0) AS infra_billed_usd,
            NOW() AS last_aggregated_at
        FROM usage_events
        WHERE event_date = $1
        GROUP BY user_id
        ON CONFLICT (user_id, date) DO UPDATE SET
            service_cost_usd = EXCLUDED.service_cost_usd,
            service_billed_usd = EXCLUDED.service_billed_usd,
            service_requests = EXCLUDED.service_requests,
            tangle_cost_usd = EXCLUDED.tangle_cost_usd,
            tangle_billed_usd = EXCLUDED.tangle_billed_usd,
            tangle_requests = EXCLUDED.tangle_requests,
            execution_count = EXCLUDED.execution_count,
            execution_billed_usd = EXCLUDED.execution_billed_usd,
            infra_cost_usd = EXCLUDED.infra_cost_usd,
            infra_billed_usd = EXCLUDED.infra_billed_usd,
            last_aggregated_at = NOW()
        "#,
    )
    .bind(date)
    .execute(pool)
    .await?;

    Ok(result.rows_affected())
}

/// Get the last aggregated date across all users.
/// Returns None if no aggregation has ever been done.
pub async fn last_aggregated_date(pool: &PgPool) -> Result<Option<chrono::NaiveDate>, sqlx::Error> {
    let row: Option<(chrono::NaiveDate,)> = sqlx::query_as(
        "SELECT MAX(date) FROM usage_daily",
    )
    .fetch_optional(pool)
    .await?;

    Ok(row.map(|(d,)| d))
}

/// Backfill daily aggregation for all missing days between last_aggregated and today.
/// Called on server startup to recover from downtime.
pub async fn backfill_daily(pool: &PgPool) -> Result<u64, sqlx::Error> {
    let today = chrono::Utc::now().date_naive();

    // Find the earliest event date that hasn't been aggregated
    let last = last_aggregated_date(pool).await?;

    let start_date = match last {
        Some(d) => d + chrono::Duration::days(1),
        None => {
            // No aggregation ever done,find earliest event
            let row: Option<(chrono::NaiveDate,)> = sqlx::query_as(
                "SELECT MIN(event_date) FROM usage_events",
            )
            .fetch_optional(pool)
            .await?;

            match row {
                Some((d,)) => d,
                None => return Ok(0), // No events at all
            }
        }
    };

    if start_date > today {
        return Ok(0);
    }

    let mut total_rows = 0u64;
    let mut current = start_date;
    while current <= today {
        let rows = aggregate_daily(pool, current).await?;
        total_rows += rows;
        current += chrono::Duration::days(1);
    }

    if total_rows > 0 {
        tracing::info!(
            "Backfilled daily usage aggregation: {} rows from {} to {}",
            total_rows,
            start_date,
            today
        );
    }

    Ok(total_rows)
}

/// Query daily usage for a user within a date range.
#[allow(non_snake_case)]
pub async fn get_daily_usage(
    pool: &PgPool,
    userId: &str,
    fromDate: chrono::NaiveDate,
    toDate: chrono::NaiveDate,
) -> Result<Vec<DailyUsage>, sqlx::Error> {
    sqlx::query_as::<_, DailyUsageRow>(
        r#"
        SELECT user_id, date,
               service_cost_usd, service_billed_usd, service_requests,
               tangle_cost_usd, tangle_billed_usd, tangle_requests,
               execution_count, execution_billed_usd,
               infra_cost_usd, infra_billed_usd
        FROM usage_daily
        WHERE user_id = $1 AND date >= $2 AND date <= $3
        ORDER BY date ASC
        "#,
    )
    .bind(userId)
    .bind(fromDate)
    .bind(toDate)
    .fetch_all(pool)
    .await
    .map(|rows| rows.into_iter().map(row_to_daily_usage).collect())
}

#[derive(Debug, Clone, serde::Serialize)]
#[allow(non_snake_case)]
pub struct DailyUsage {
    pub userId: String,
    pub date: String,
    pub serviceCostUsd: f64,
    pub serviceBilledUsd: f64,
    pub serviceRequests: i32,
    pub tangleCostUsd: f64,
    pub tangleBilledUsd: f64,
    pub tangleRequests: i32,
    pub executionCount: i32,
    pub executionBilledUsd: f64,
    pub infraCostUsd: f64,
    pub infraBilledUsd: f64,
}

type DailyUsageRow = (
    String,              // user_id
    chrono::NaiveDate,   // date
    f64,                 // service_cost_usd
    f64,                 // service_billed_usd
    i32,                 // service_requests
    f64,                 // tangle_cost_usd
    f64,                 // tangle_billed_usd
    i32,                 // tangle_requests
    i32,                 // execution_count
    f64,                 // execution_billed_usd
    f64,                 // infra_cost_usd
    f64,                 // infra_billed_usd
);

fn row_to_daily_usage(row: DailyUsageRow) -> DailyUsage {
    DailyUsage {
        userId: row.0,
        date: row.1.to_string(),
        serviceCostUsd: row.2,
        serviceBilledUsd: row.3,
        serviceRequests: row.4,
        tangleCostUsd: row.5,
        tangleBilledUsd: row.6,
        tangleRequests: row.7,
        executionCount: row.8,
        executionBilledUsd: row.9,
        infraCostUsd: row.10,
        infraBilledUsd: row.11,
    }
}

// ── Per-execution cost query ──

/// Get the total billed cost for a single execution (service + execution fees, excludes infra/tangle).
pub async fn get_execution_cost(
    pool: &PgPool,
    execution_id: &str,
    user_id: Option<&str>,
) -> Result<f64, sqlx::Error> {
    let row: Option<(f64,)> = match user_id {
        Some(uid) => {
            sqlx::query_as(
                "SELECT COALESCE(SUM(billed_usd), 0) FROM usage_events WHERE execution_id = $1 AND user_id = $2 AND event_type IN ('service', 'execution')",
            )
            .bind(execution_id)
            .bind(uid)
            .fetch_optional(pool)
            .await?
        }
        None => {
            sqlx::query_as(
                "SELECT COALESCE(SUM(billed_usd), 0) FROM usage_events WHERE execution_id = $1 AND event_type IN ('service', 'execution')",
            )
            .bind(execution_id)
            .fetch_optional(pool)
            .await?
        }
    };

    Ok(row.map(|(c,)| c).unwrap_or(0.0))
}

// ── Credit balance queries ──

/// Get a user's current credit balance. Returns 0.0 if user has no credits row.
pub async fn get_balance(pool: &PgPool, user_id: &str) -> Result<f64, sqlx::Error> {
    let row: Option<(f64,)> = sqlx::query_as(
        "SELECT balance_usd FROM user_credits WHERE user_id = $1",
    )
    .bind(user_id)
    .fetch_optional(pool)
    .await?;

    Ok(row.map(|(b,)| b).unwrap_or(0.0))
}

/// Check if a user has sufficient balance to start infrastructure.
/// Requires $5 reserve per running infra instance (including the one about to start).
/// Returns Ok(()) if allowed, Err(message) if not.
pub async fn check_infra_start_allowed(
    pool: &PgPool,
    user_id: &str,
    current_running_count: i64,
) -> Result<(), String> {
    let balance = get_balance(pool, user_id).await
        .map_err(|e| format!("Failed to check balance: {}", e))?;

    let required = 5.0 * (current_running_count + 1) as f64;

    if balance < required {
        Err(format!(
            "Insufficient credits to start infrastructure. Balance: ${:.2}, required: ${:.2} (${:.2} reserve per running instance, {} currently running)",
            balance, required, 5.0, current_running_count
        ))
    } else {
        Ok(())
    }
}
