use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::IntoResponse,
    routing::{get, post},
    Json, Router,
};

// NEW: needed to deserialize WorkerMessage::Batch
use crate::worker::WorkerMessage;

// CHANGED: add ToHex
use hex::{FromHex, ToHex};

// CHANGED: add Serialize
use serde::{Deserialize, Serialize};

use std::net::SocketAddr;
use store::Store;


// ============================================================================
// STORAGE KEY
// ============================================================================

/// Key format: b"batch:" || 32-byte digest
fn batch_store_key(digest32: &[u8]) -> Vec<u8> {
    let mut k = b"batch:".to_vec();
    k.extend_from_slice(digest32);
    k
}


// ============================================================================
// EXISTING RAW BATCH ENDPOINT
// ============================================================================

/// GET /batch/<digest_hex_without_0x>
/// Returns the raw serialized WorkerMessage::Batch(...) bytes
async fn get_batch(
    Path(dhex): Path<String>,
    State(mut store): State<Store>,
) -> Result<impl IntoResponse, StatusCode> {

    let digest = Vec::from_hex(dhex)
        .map_err(|_| StatusCode::BAD_REQUEST)?;

    if digest.len() != 32 {
        return Err(StatusCode::BAD_REQUEST);
    }

    // 1) Try new key:
    //    "batch:" || keccak digest bytes
    let k1 = batch_store_key(&digest);

    match store.read(k1).await {
        Ok(Some(bytes)) => return Ok(bytes),

        Ok(None) => {
            // Fall through to old/raw key.
        }

        Err(_) => {
            return Err(StatusCode::INTERNAL_SERVER_ERROR);
        }
    }


    // 2) Fallback:
    //    try raw digest bytes
    let k2 = digest.clone();

    match store.read(k2).await {
        Ok(Some(bytes)) => Ok(bytes),

        Ok(None) => Err(StatusCode::NOT_FOUND),

        Err(_) => Err(StatusCode::INTERNAL_SERVER_ERROR),
    }
}


// ============================================================================
// NEW: JSON FORMAT EXPECTED BY GETH
// ============================================================================

#[derive(Debug, Serialize)]
struct BatchJson {
    digest: String,
    txs: Vec<String>,
}


// ============================================================================
// NEW: GET /batch_json/<digest>
//
// Returns:
//
// {
//     "digest": "0x...",
//     "txs": [
//         "0xf86c...",
//         "0xf86a..."
//     ]
// }
//
// The transaction bytes are NOT reconstructed.
// We deserialize the Narwhal batch and hex-encode each original Vec<u8>.
// ============================================================================

async fn get_batch_json(
    Path(dhex): Path<String>,
    State(mut store): State<Store>,
) -> Result<Json<BatchJson>, StatusCode> {

    // ------------------------------------------------------------------------
    // 1. Accept digest with or without 0x
    // ------------------------------------------------------------------------

    let dhex = dhex.strip_prefix("0x").unwrap_or(&dhex);


    // ------------------------------------------------------------------------
    // 2. Convert hex digest -> bytes
    // ------------------------------------------------------------------------

    let digest = Vec::from_hex(dhex).map_err(|e| {

        eprintln!(
            "[worker_http] batch_json invalid digest={} error={:?}",
            dhex,
            e
        );

        StatusCode::BAD_REQUEST
    })?;


    if digest.len() != 32 {

        eprintln!(
            "[worker_http] batch_json invalid digest length={} digest={}",
            digest.len(),
            dhex
        );

        return Err(StatusCode::BAD_REQUEST);
    }


    // ------------------------------------------------------------------------
    // 3. Build same key used by processor.rs
    //
    //      b"batch:" || keccak_digest
    // ------------------------------------------------------------------------

    let key = batch_store_key(&digest);


    // ------------------------------------------------------------------------
    // 4. Read exact serialized WorkerMessage::Batch
    // ------------------------------------------------------------------------

    let serialized = match store.read(key).await {

        Ok(Some(bytes)) => bytes,

        Ok(None) => {

            eprintln!(
                "[worker_http] batch_json NOT FOUND digest=0x{}",
                dhex
            );

            return Err(StatusCode::NOT_FOUND);
        }

        Err(e) => {

            eprintln!(
                "[worker_http] batch_json store error digest=0x{} error={:?}",
                dhex,
                e
            );

            return Err(StatusCode::INTERNAL_SERVER_ERROR);
        }
    };


    eprintln!(
        "[worker_http] batch_json STORAGE HIT digest=0x{} bytes={}",
        dhex,
        serialized.len()
    );


    // ------------------------------------------------------------------------
    // 5. Deserialize WorkerMessage
    //
    // Original creation in batch_maker.rs:
    //
    //      let message = WorkerMessage::Batch(batch);
    //      let serialized = bincode::serialize(&message);
    //
    // Therefore this is the exact inverse.
    // ------------------------------------------------------------------------

    let message: WorkerMessage =
        bincode::deserialize(&serialized).map_err(|e| {

            eprintln!(
                "[worker_http] batch_json DESERIALIZE FAILED \
                 digest=0x{} bytes={} error={:?}",
                dhex,
                serialized.len(),
                e
            );

            StatusCode::INTERNAL_SERVER_ERROR
        })?;


    // ------------------------------------------------------------------------
    // 6. Extract the batch
    //
    // Batch = Vec<Transaction>
    // Transaction = Vec<u8>
    // ------------------------------------------------------------------------

    let batch = match message {

        WorkerMessage::Batch(batch) => batch,

        _ => {

            eprintln!(
                "[worker_http] batch_json digest=0x{} \
                 is not WorkerMessage::Batch",
                dhex
            );

            return Err(StatusCode::INTERNAL_SERVER_ERROR);
        }
    };


    // ------------------------------------------------------------------------
    // 7. Convert each ORIGINAL transaction byte array to hex
    //
    // We are NOT:
    //
    // - decoding Ethereum transaction fields
    // - rebuilding the transaction
    // - changing nonce
    // - changing gas
    // - changing chain ID
    // - changing signature
    //
    // Only:
    //
    //      Vec<u8> -> "0x..."
    // ------------------------------------------------------------------------

    let txs: Vec<String> = batch
        .iter()
        .map(|tx| {
            format!(
                "0x{}",
                tx.encode_hex::<String>()
            )
        })
        .collect();


    eprintln!(
        "[worker_http] batch_json FOUND digest=0x{} txs={} serialized_bytes={}",
        dhex,
        txs.len(),
        serialized.len()
    );


    // Print first tx information for debugging.
    if let Some(first_tx) = batch.first() {

        let prefix: String = first_tx
            .iter()
            .take(16)
            .copied()
            .collect::<Vec<u8>>()
            .encode_hex();

        eprintln!(
            "[worker_http] batch_json first_tx bytes={} prefix=0x{}",
            first_tx.len(),
            prefix
        );
    }


    // ------------------------------------------------------------------------
    // 8. Return JSON to Geth
    // ------------------------------------------------------------------------

    Ok(Json(BatchJson {

        digest: format!("0x{}", dhex),

        txs,
    }))
}


// ============================================================================
// EXISTING EXECUTION RESULT
// ============================================================================

/// Optional: sidecar can report execution results back to workers
#[derive(Debug, Deserialize)]
pub struct ExecResult {
    pub digest: String,          // "0x..."
    pub tx_hashes: Vec<String>,  // "0x..."
    pub success: bool,
    pub block_number: Option<u64>,
}


async fn post_exec_result(
    Json(r): Json<ExecResult>,
) -> StatusCode {

    eprintln!(
        "[worker_http] exec_result digest={} success={} txs={} block={:?}",
        r.digest,
        r.success,
        r.tx_hashes.len(),
        r.block_number
    );

    StatusCode::OK
}


// ============================================================================
// HTTP SERVER
// ============================================================================

pub fn spawn_worker_http(
    store: Store,
    addr: SocketAddr,
) {

    tokio::spawn(async move {

        let app = Router::new()

            // Existing raw binary endpoint.
            .route(
                "/batch/:digest",
                get(get_batch),
            )

            // NEW endpoint for Geth.
            .route(
                "/batch_json/:digest",
                get(get_batch_json),
            )

            // Existing execution result endpoint.
            .route(
                "/exec_result",
                post(post_exec_result),
            )

            .with_state(store);


        let listener =
            match tokio::net::TcpListener::bind(addr).await {

                Ok(l) => l,

                Err(e) => {

                    eprintln!(
                        "Worker HTTP bind failed on {}: {}",
                        addr,
                        e
                    );

                    return;
                }
            };


        eprintln!(
            "[worker_http] HTTP server listening on {}",
            addr
        );


        if let Err(e) =
            axum::serve(listener, app).await
        {
            eprintln!(
                "[worker_http] HTTP server error: {:?}",
                e
            );
        }
    });
}