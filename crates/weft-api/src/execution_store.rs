use sqlx::PgPool;

/// Insert a new execution record (status = 'running').
pub async fn create_execution(
    pool: &PgPool,
    id: &str,
    project_id: &str,
    user_id: &str,
    trigger_id: Option<&str>,
    node_type: Option<&str>,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        r#"
        INSERT INTO executions (id, project_id, user_id, trigger_id, node_type, status)
        VALUES ($1, $2::uuid, $3, $4, $5, 'running')
        ON CONFLICT (id) DO NOTHING
        "#,
    )
    .bind(id)
    .bind(project_id)
    .bind(user_id)
    .bind(trigger_id)
    .bind(node_type)
    .execute(pool)
    .await?;

    Ok(())
}

/// Update execution status (and set completed_at for terminal states).
pub async fn update_execution_status(
    pool: &PgPool,
    id: &str,
    status: &str,
    error: Option<&str>,
) -> Result<(), sqlx::Error> {
    let terminal = matches!(status, "completed" | "failed" | "cancelled");

    if terminal {
        sqlx::query(
            r#"
            UPDATE executions
            SET status = $1, error = $2, completed_at = NOW()
            WHERE id = $3
            "#,
        )
        .bind(status)
        .bind(error)
        .bind(id)
        .execute(pool)
        .await?;
    } else {
        sqlx::query(
            r#"
            UPDATE executions
            SET status = $1, error = $2
            WHERE id = $3
            "#,
        )
        .bind(status)
        .bind(error)
        .bind(id)
        .execute(pool)
        .await?;
    }

    Ok(())
}
