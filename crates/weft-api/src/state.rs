use std::sync::Arc;
use tokio::sync::Mutex;
use weft_nodes::TriggerService;
use sqlx::PgPool;

use crate::trigger_store;

pub struct AppState {
    pub trigger_service: Arc<Mutex<TriggerService>>,
    pub restate_url: String,
    pub restate_admin_url: String,
    pub executor_url: String,
    pub db_pool: PgPool,
    pub instance_id: String,
    pub http_client: reqwest::Client,
    pub node_registry: &'static weft_nodes::NodeTypeRegistry,
}

impl AppState {
    pub async fn new() -> Self {
        let restate_url = std::env::var("RESTATE_URL")
            .unwrap_or_else(|_| "http://localhost:8180".to_string());
        let restate_admin_url = std::env::var("RESTATE_ADMIN_URL")
            .unwrap_or_else(|_| {
                restate_url.replace(":8080", ":9070").replace(":8180", ":9170")
            });
        let executor_url = std::env::var("EXECUTOR_URL")
            .unwrap_or_else(|_| "http://localhost:9081".to_string());
        
        // Generate unique instance ID for trigger claiming
        let instance_id = trigger_store::generate_instance_id();
        tracing::info!("Instance ID: {}", instance_id);
        
        // Initialize PostgreSQL database - REQUIRED, crash if unavailable
        let db_pool = Self::init_database().await
            .expect("Failed to connect to database. DATABASE_URL must be set and database must be reachable.");
        
        let node_registry: &'static weft_nodes::NodeTypeRegistry =
            Box::leak(Box::new(weft_nodes::NodeTypeRegistry::new()));

        Self {
            trigger_service: Arc::new(Mutex::new(TriggerService::with_registry(node_registry))),
            restate_url,
            restate_admin_url,
            executor_url,
            db_pool,
            instance_id,
            http_client: reqwest::Client::new(),
            node_registry,
        }
    }
    
    async fn init_database() -> Result<PgPool, sqlx::Error> {
        let database_url = std::env::var("DATABASE_URL")
            .unwrap_or_else(|_| "postgres://postgres:postgres@localhost:5433/weft_local".to_string());
        
        tracing::info!("Connecting to PostgreSQL database");
        
        let pool = PgPool::connect(&database_url).await?;

        // Incremental schema migrations (idempotent)
        sqlx::query(
            "ALTER TABLE triggers ADD COLUMN IF NOT EXISTS project_definition JSONB"
        )
        .execute(&pool)
        .await
        .map_err(|e| {
            tracing::error!("Failed to run schema migration: {}", e);
            e
        })?;

        sqlx::query(
            "CREATE TABLE IF NOT EXISTS infra_pending_action (
                project_id TEXT PRIMARY KEY,
                action TEXT NOT NULL,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )"
        )
        .execute(&pool)
        .await
        .map_err(|e| {
            tracing::error!("Failed to create infra_pending_action table: {}", e);
            e
        })?;
        
        Ok(pool)
    }
}
