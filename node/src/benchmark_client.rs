// Copyright(C) Facebook, Inc. and its affiliates.

use anyhow::{Context, Result};
use bytes::Bytes;
use chrono::{TimeZone, Utc};
use clap::{crate_name, crate_version, App, AppSettings};
use env_logger::Env;
use futures::future::join_all;
use futures::sink::SinkExt as _;
use log::{info, warn};
use reqwest::Client as HttpClient;
use rust_xlsxwriter::{Format, FormatAlign, Workbook, XlsxError};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::fs::File;
use std::io::Read;
use std::net::SocketAddr;
use std::path::Path;
use tiny_keccak::{Hasher, Keccak};
use tokio::net::TcpStream;
use tokio::time::{interval, sleep, Duration, Instant};
use tokio_util::codec::{Framed, LengthDelimitedCodec};

#[tokio::main]
async fn main() -> Result<()> {
    let matches = App::new(crate_name!())
        .version(crate_version!())
        .about("Benchmark client for Narwhal and Geth latency metrics.")
        .args_from_usage("<ADDR> 'Narwhal worker transaction address'")
        .args_from_usage("--size=<INT> 'Compatibility option; raw Ethereum tx size comes from file'")
        .args_from_usage("--rate=<INT> 'Target transactions per second'")
        .args_from_usage("--nodes=[ADDR]... 'Addresses that must be reachable before starting'")
        .setting(AppSettings::ArgRequiredElseHelp)
        .get_matches();

    env_logger::Builder::from_env(Env::default().default_filter_or("info"))
        .format_timestamp_millis()
        .init();

    let target = matches
        .value_of("ADDR")
        .unwrap()
        .parse::<SocketAddr>()
        .context("Invalid socket address format")?;

    let size = matches
        .value_of("size")
        .unwrap()
        .parse::<usize>()
        .context("Invalid transaction size")?;

    let rate = matches
        .value_of("rate")
        .unwrap()
        .parse::<u64>()
        .context("Invalid transaction rate")?;

    if rate == 0 {
        return Err(anyhow::anyhow!("--rate must be greater than zero"));
    }

    let nodes = matches
        .values_of("nodes")
        .unwrap_or_default()
        .map(|value| value.parse::<SocketAddr>())
        .collect::<std::result::Result<Vec<_>, _>>()
        .context("Invalid node address")?;

    info!("Narwhal target: {}", target);
    info!("Compatibility size: {} B", size);
    info!("Target rate: {} tx/s", rate);

    let client = Client {
        target,
        size,
        rate,
        nodes,
    };

    client.wait().await;
    client.send().await.context("Failed to submit transactions")
}

struct Client {
    target: SocketAddr,
    #[allow(dead_code)]
    size: usize,
    rate: u64,
    nodes: Vec<SocketAddr>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct TxMetric {
    tx_index: usize,
    tx_hash: String,
    raw_tx_size_bytes: usize,

    send_time_utc: String,
    send_epoch_ms: i64,

    receipt_observed_time_utc: Option<String>,
    receipt_observed_epoch_ms: Option<i64>,

    block_number: Option<u64>,
    block_timestamp_utc: Option<String>,
    block_timestamp_epoch_ms: Option<i64>,

    inclusion_latency_sec: Option<f64>,
    receipt_observed_latency_sec: Option<f64>,

    status: String,
    gas_used: Option<u64>,
    error: String,
}

#[derive(Debug, Clone)]
struct ReceiptInfo {
    block_number: u64,
    status: bool,
    gas_used: u64,
}

#[derive(Debug)]
struct SummaryMetrics {
    total_transactions: usize,
    successful_transactions: usize,
    failed_transactions: usize,
    timeout_transactions: usize,
    send_duration_sec: f64,
    actual_send_rate_tps: f64,
    average_inclusion_latency_sec: f64,
    min_inclusion_latency_sec: f64,
    max_inclusion_latency_sec: f64,
    average_observed_latency_sec: f64,
    min_observed_latency_sec: f64,
    max_observed_latency_sec: f64,
}

fn parse_transactions_from_text(text: &str) -> Result<Vec<Vec<u8>>> {
    let mut transactions = Vec::new();
    let mut index = 0usize;
    let bytes = text.as_bytes();

    while index < bytes.len() {
        while index < bytes.len() && bytes[index] != b'[' {
            index += 1;
        }
        if index >= bytes.len() {
            break;
        }
        index += 1;

        let start = index;
        while index < bytes.len() && bytes[index] != b']' {
            index += 1;
        }
        if index >= bytes.len() {
            return Err(anyhow::anyhow!("Unclosed '[' in transaction file"));
        }

        let inner = &text[start..index];
        index += 1;

        let mut transaction = Vec::new();

        for token in inner.split(',') {
            let token = token.trim();
            if token.is_empty() {
                continue;
            }

            let value = if let Some(hex_value) = token.strip_prefix("0x") {
                u8::from_str_radix(hex_value, 16)
                    .with_context(|| format!("Invalid hexadecimal byte: {}", token))?
            } else {
                token
                    .parse::<u8>()
                    .with_context(|| format!("Invalid decimal byte: {}", token))?
            };

            transaction.push(value);
        }

        if !transaction.is_empty() {
            transactions.push(transaction);
        }
    }

    if transactions.is_empty() {
        return Err(anyhow::anyhow!(
            "No '[ ... ]' transactions found in transaction file"
        ));
    }

    Ok(transactions)
}

fn ethereum_tx_hash(raw_tx: &[u8]) -> String {
    let mut output = [0u8; 32];
    let mut hasher = Keccak::v256();
    hasher.update(raw_tx);
    hasher.finalize(&mut output);
    format!("0x{}", hex::encode(output))
}

impl Client {
    async fn send(&self) -> Result<()> {
        let transaction_file = std::env::var("TRANSACTION_FILE").unwrap_or_else(|_| {
            "/home/narwhal/narwhal/thirdparty/test_evm/transaction.txt".to_string()
        });

        let geth_rpc_url = std::env::var("GETH_RPC_URL")
            .unwrap_or_else(|_| "http://el-01-geth-lighthouse:8545".to_string());

        let output_xlsx = std::env::var("METRICS_XLSX")
            .unwrap_or_else(|_| "narwhal_geth_metrics.xlsx".to_string());

        let receipt_timeout_sec = env_u64("RECEIPT_TIMEOUT_SEC", 600);
        let receipt_poll_ms = env_u64("RECEIPT_POLL_MS", 1000);

        let mut file = File::open(&transaction_file)
            .with_context(|| format!("Failed to open {}", transaction_file))?;

        let mut text = String::new();
        file.read_to_string(&mut text)
            .with_context(|| format!("Failed to read {}", transaction_file))?;

        let parsed = parse_transactions_from_text(&text)?;
        let transactions: Vec<Bytes> = parsed.into_iter().map(Bytes::from).collect();

        info!(
            "Loaded {} signed Ethereum transactions from {}",
            transactions.len(),
            transaction_file
        );

        let stream = TcpStream::connect(self.target)
            .await
            .with_context(|| format!("Failed to connect to {}", self.target))?;

        let mut transport = Framed::new(stream, LengthDelimitedCodec::new());

        // One timer tick per transaction gives a direct target rate.
        let period = Duration::from_secs_f64(1.0 / self.rate as f64);
        let ticker = interval(period);
        tokio::pin!(ticker);

        let send_start = Instant::now();
        let mut metrics = Vec::with_capacity(transactions.len());

        for (tx_index, raw_tx) in transactions.iter().enumerate() {
            ticker.as_mut().tick().await;

            let tx_hash = ethereum_tx_hash(raw_tx.as_ref());
            let send_time = Utc::now();

            transport
                .send(raw_tx.clone())
                .await
                .with_context(|| {
                    format!(
                        "Failed to send transaction index={} hash={}",
                        tx_index, tx_hash
                    )
                })?;

            metrics.push(TxMetric {
                tx_index,
                tx_hash: tx_hash.clone(),
                raw_tx_size_bytes: raw_tx.len(),
                send_time_utc: send_time.to_rfc3339(),
                send_epoch_ms: send_time.timestamp_millis(),
                receipt_observed_time_utc: None,
                receipt_observed_epoch_ms: None,
                block_number: None,
                block_timestamp_utc: None,
                block_timestamp_epoch_ms: None,
                inclusion_latency_sec: None,
                receipt_observed_latency_sec: None,
                status: "SENT_TO_NARWHAL".to_string(),
                gas_used: None,
                error: String::new(),
            });

            info!(
                "TX SENT TO NARWHAL index={} hash={} bytes={} time={}",
                tx_index,
                tx_hash,
                raw_tx.len(),
                send_time.to_rfc3339()
            );
        }

        transport
            .flush()
            .await
            .context("Failed to flush Narwhal transaction stream")?;

        let send_duration_sec = send_start.elapsed().as_secs_f64();
        let actual_rate = if send_duration_sec > 0.0 {
            metrics.len() as f64 / send_duration_sec
        } else {
            0.0
        };

        info!(
            "Finished Narwhal send phase txs={} duration={:.3}s rate={:.2} tx/s",
            metrics.len(),
            send_duration_sec,
            actual_rate
        );

        collect_receipts(
            &mut metrics,
            &geth_rpc_url,
            Duration::from_secs(receipt_timeout_sec),
            Duration::from_millis(receipt_poll_ms),
        )
        .await;

        let summary = calculate_summary(&metrics, send_duration_sec);

        write_excel(&output_xlsx, &metrics, &summary).map_err(|error| {
            anyhow::anyhow!("Failed to save Excel {}: {}", output_xlsx, error)
        })?;

        info!("Excel metrics saved to {}", output_xlsx);
        Ok(())
    }

    async fn wait(&self) {
        info!("Waiting for all nodes to be online...");

        join_all(self.nodes.iter().copied().map(|address| {
            tokio::spawn(async move {
                while TcpStream::connect(address).await.is_err() {
                    sleep(Duration::from_millis(10)).await;
                }
            })
        }))
        .await;
    }
}

fn env_u64(name: &str, default: u64) -> u64 {
    std::env::var(name)
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(default)
}

async fn rpc_call(
    client: &HttpClient,
    geth_rpc_url: &str,
    method: &str,
    params: Value,
) -> Result<Value> {
    let request = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": method,
        "params": params,
    });

    let response = client
        .post(geth_rpc_url)
        .json(&request)
        .send()
        .await
        .with_context(|| format!("RPC request failed: {}", method))?;

    let status = response.status();
    let body: Value = response
        .json()
        .await
        .with_context(|| format!("Invalid RPC response: {}", method))?;

    if !status.is_success() {
        return Err(anyhow::anyhow!(
            "RPC HTTP error method={} status={} body={}",
            method,
            status,
            body
        ));
    }

    if let Some(error) = body.get("error") {
        return Err(anyhow::anyhow!(
            "RPC error method={} error={}",
            method,
            error
        ));
    }

    Ok(body.get("result").cloned().unwrap_or(Value::Null))
}

fn parse_hex_u64(value: &str) -> Result<u64> {
    let clean = value.trim_start_matches("0x");

    if clean.is_empty() {
        return Ok(0);
    }

    u64::from_str_radix(clean, 16)
        .with_context(|| format!("Invalid hexadecimal integer: {}", value))
}

async fn get_transaction_receipt(
    client: &HttpClient,
    geth_rpc_url: &str,
    tx_hash: &str,
) -> Result<Option<ReceiptInfo>> {
    let result = rpc_call(
        client,
        geth_rpc_url,
        "eth_getTransactionReceipt",
        json!([tx_hash]),
    )
    .await?;

    if result.is_null() {
        return Ok(None);
    }

    let block_number = result
        .get("blockNumber")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow::anyhow!("Receipt missing blockNumber"))?;

    let status = result
        .get("status")
        .and_then(Value::as_str)
        .unwrap_or("0x0");

    let gas_used = result
        .get("gasUsed")
        .and_then(Value::as_str)
        .unwrap_or("0x0");

    Ok(Some(ReceiptInfo {
        block_number: parse_hex_u64(block_number)?,
        status: parse_hex_u64(status)? == 1,
        gas_used: parse_hex_u64(gas_used)?,
    }))
}

async fn get_block_timestamp(
    client: &HttpClient,
    geth_rpc_url: &str,
    block_number: u64,
) -> Result<i64> {
    let block_tag = format!("0x{:x}", block_number);

    let result = rpc_call(
        client,
        geth_rpc_url,
        "eth_getBlockByNumber",
        json!([block_tag, false]),
    )
    .await?;

    if result.is_null() {
        return Err(anyhow::anyhow!("Block {} was not found", block_number));
    }

    let timestamp = result
        .get("timestamp")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow::anyhow!("Block missing timestamp"))?;

    Ok(parse_hex_u64(timestamp)? as i64)
}

async fn collect_receipts(
    metrics: &mut [TxMetric],
    geth_rpc_url: &str,
    timeout: Duration,
    poll_interval: Duration,
) {
    let client = match HttpClient::builder()
        .timeout(Duration::from_secs(5))
        .build()
    {
        Ok(client) => client,
        Err(error) => {
            for metric in metrics {
                metric.status = "RPC_CLIENT_ERROR".to_string();
                metric.error = error.to_string();
            }
            return;
        }
    };

    let deadline = Instant::now() + timeout;
    let mut pending: Vec<usize> = (0..metrics.len()).collect();
    let mut block_cache: HashMap<u64, i64> = HashMap::new();

    while !pending.is_empty() && Instant::now() < deadline {
        let mut still_pending = Vec::new();

        for metric_index in pending {
            let tx_hash = metrics[metric_index].tx_hash.clone();

            match get_transaction_receipt(&client, geth_rpc_url, &tx_hash).await {
                Ok(Some(receipt)) => {
                    let receipt_observed = Utc::now();

                    let block_timestamp_sec =
                        if let Some(timestamp) = block_cache.get(&receipt.block_number) {
                            *timestamp
                        } else {
                            match get_block_timestamp(
                                &client,
                                geth_rpc_url,
                                receipt.block_number,
                            )
                            .await
                            {
                                Ok(timestamp) => {
                                    block_cache.insert(receipt.block_number, timestamp);
                                    timestamp
                                }
                                Err(error) => {
                                    metrics[metric_index].status =
                                        "BLOCK_FETCH_ERROR".to_string();
                                    metrics[metric_index].error = error.to_string();
                                    continue;
                                }
                            }
                        };

                    let block_timestamp_ms = block_timestamp_sec * 1000;
                    let send_epoch_ms = metrics[metric_index].send_epoch_ms;
                    let observed_epoch_ms = receipt_observed.timestamp_millis();

                    metrics[metric_index].receipt_observed_time_utc =
                        Some(receipt_observed.to_rfc3339());
                    metrics[metric_index].receipt_observed_epoch_ms =
                        Some(observed_epoch_ms);
                    metrics[metric_index].block_number = Some(receipt.block_number);
                    metrics[metric_index].block_timestamp_epoch_ms =
                        Some(block_timestamp_ms);
                    metrics[metric_index].block_timestamp_utc =
                        Utc.timestamp_opt(block_timestamp_sec, 0)
                            .single()
                            .map(|value| value.to_rfc3339());

                    metrics[metric_index].inclusion_latency_sec =
                        Some((block_timestamp_ms - send_epoch_ms) as f64 / 1000.0);

                    metrics[metric_index].receipt_observed_latency_sec =
                        Some((observed_epoch_ms - send_epoch_ms) as f64 / 1000.0);

                    metrics[metric_index].status = if receipt.status {
                        "SUCCESS".to_string()
                    } else {
                        "FAILED".to_string()
                    };

                    metrics[metric_index].gas_used = Some(receipt.gas_used);

                    info!(
                        "TX CONFIRMED index={} hash={} block={} status={} inclusion_latency={:.3}s observed_latency={:.3}s",
                        metrics[metric_index].tx_index,
                        tx_hash,
                        receipt.block_number,
                        metrics[metric_index].status,
                        metrics[metric_index]
                            .inclusion_latency_sec
                            .unwrap_or_default(),
                        metrics[metric_index]
                            .receipt_observed_latency_sec
                            .unwrap_or_default(),
                    );
                }
                Ok(None) => still_pending.push(metric_index),
                Err(error) => {
                    warn!(
                        "Receipt request failed hash={} error={}",
                        tx_hash, error
                    );
                    still_pending.push(metric_index);
                }
            }
        }

        pending = still_pending;

        if !pending.is_empty() {
            sleep(poll_interval).await;
        }
    }

    for metric_index in pending {
        metrics[metric_index].status = "DROPPED_OR_TIMEOUT".to_string();
        metrics[metric_index].error = format!(
            "Receipt not found within {} seconds",
            timeout.as_secs()
        );
    }
}

fn calculate_summary(
    metrics: &[TxMetric],
    send_duration_sec: f64,
) -> SummaryMetrics {
    let inclusion_values: Vec<f64> = metrics
        .iter()
        .filter_map(|metric| metric.inclusion_latency_sec)
        .collect();

    let observed_values: Vec<f64> = metrics
        .iter()
        .filter_map(|metric| metric.receipt_observed_latency_sec)
        .collect();

    let successful_transactions = metrics
        .iter()
        .filter(|metric| metric.status == "SUCCESS")
        .count();

    let failed_transactions = metrics
        .iter()
        .filter(|metric| metric.status == "FAILED")
        .count();

    let timeout_transactions = metrics
        .iter()
        .filter(|metric| metric.status == "DROPPED_OR_TIMEOUT")
        .count();

    SummaryMetrics {
        total_transactions: metrics.len(),
        successful_transactions,
        failed_transactions,
        timeout_transactions,
        send_duration_sec,
        actual_send_rate_tps: if send_duration_sec > 0.0 {
            metrics.len() as f64 / send_duration_sec
        } else {
            0.0
        },
        average_inclusion_latency_sec: average(&inclusion_values),
        min_inclusion_latency_sec: minimum(&inclusion_values),
        max_inclusion_latency_sec: maximum(&inclusion_values),
        average_observed_latency_sec: average(&observed_values),
        min_observed_latency_sec: minimum(&observed_values),
        max_observed_latency_sec: maximum(&observed_values),
    }
}

fn average(values: &[f64]) -> f64 {
    if values.is_empty() {
        0.0
    } else {
        values.iter().sum::<f64>() / values.len() as f64
    }
}

fn minimum(values: &[f64]) -> f64 {
    values.iter().copied().reduce(f64::min).unwrap_or(0.0)
}

fn maximum(values: &[f64]) -> f64 {
    values.iter().copied().reduce(f64::max).unwrap_or(0.0)
}

fn write_excel(
    output_path: &str,
    metrics: &[TxMetric],
    summary: &SummaryMetrics,
) -> std::result::Result<(), XlsxError> {
    let mut workbook = Workbook::new();

    let header_format = Format::new()
        .set_bold()
        .set_align(FormatAlign::Center);

    let decimal_format = Format::new().set_num_format("0.000");

    let detail = workbook.add_worksheet();
    detail.set_name("per_transaction")?;

    let headers = [
        "tx_index",
        "tx_hash",
        "raw_tx_size_bytes",
        "send_time_utc",
        "send_epoch_ms",
        "receipt_observed_time_utc",
        "receipt_observed_epoch_ms",
        "block_number",
        "block_timestamp_utc",
        "block_timestamp_epoch_ms",
        "inclusion_latency_sec",
        "receipt_observed_latency_sec",
        "status",
        "gas_used",
        "error",
    ];

    for (column, header) in headers.iter().enumerate() {
        detail.write_with_format(0, column as u16, *header, &header_format)?;
    }

    for (row_index, metric) in metrics.iter().enumerate() {
        let row = (row_index + 1) as u32;

        detail.write_number(row, 0, metric.tx_index as f64)?;
        detail.write_string(row, 1, &metric.tx_hash)?;
        detail.write_number(row, 2, metric.raw_tx_size_bytes as f64)?;
        detail.write_string(row, 3, &metric.send_time_utc)?;
        detail.write_number(row, 4, metric.send_epoch_ms as f64)?;

        if let Some(value) = &metric.receipt_observed_time_utc {
            detail.write_string(row, 5, value)?;
        }
        if let Some(value) = metric.receipt_observed_epoch_ms {
            detail.write_number(row, 6, value as f64)?;
        }
        if let Some(value) = metric.block_number {
            detail.write_number(row, 7, value as f64)?;
        }
        if let Some(value) = &metric.block_timestamp_utc {
            detail.write_string(row, 8, value)?;
        }
        if let Some(value) = metric.block_timestamp_epoch_ms {
            detail.write_number(row, 9, value as f64)?;
        }
        if let Some(value) = metric.inclusion_latency_sec {
            detail.write_number_with_format(row, 10, value, &decimal_format)?;
        }
        if let Some(value) = metric.receipt_observed_latency_sec {
            detail.write_number_with_format(row, 11, value, &decimal_format)?;
        }

        detail.write_string(row, 12, &metric.status)?;

        if let Some(value) = metric.gas_used {
            detail.write_number(row, 13, value as f64)?;
        }

        detail.write_string(row, 14, &metric.error)?;
    }

    detail.set_column_width(0, 12)?;
    detail.set_column_width(1, 70)?;
    detail.set_column_width(2, 18)?;
    detail.set_column_width(3, 32)?;
    detail.set_column_width(5, 32)?;
    detail.set_column_width(8, 32)?;
    detail.set_column_width(10, 24)?;
    detail.set_column_width(11, 30)?;
    detail.set_column_width(12, 22)?;
    detail.set_column_width(14, 50)?;
    detail.set_freeze_panes(1, 0)?;

    let summary_sheet = workbook.add_worksheet();
    summary_sheet.set_name("overall_summary")?;

    summary_sheet.write_with_format(0, 0, "Metric", &header_format)?;
    summary_sheet.write_with_format(0, 1, "Value", &header_format)?;

    let summary_rows: Vec<(&str, f64)> = vec![
        ("Total transactions", summary.total_transactions as f64),
        (
            "Successful transactions",
            summary.successful_transactions as f64,
        ),
        ("Failed transactions", summary.failed_transactions as f64),
        (
            "Receipt timeout transactions",
            summary.timeout_transactions as f64,
        ),
        ("Send phase duration sec", summary.send_duration_sec),
        ("Actual send rate tx/sec", summary.actual_send_rate_tps),
        (
            "Average inclusion latency sec",
            summary.average_inclusion_latency_sec,
        ),
        (
            "Min inclusion latency sec",
            summary.min_inclusion_latency_sec,
        ),
        (
            "Max inclusion latency sec",
            summary.max_inclusion_latency_sec,
        ),
        (
            "Average receipt observed latency sec",
            summary.average_observed_latency_sec,
        ),
        (
            "Min receipt observed latency sec",
            summary.min_observed_latency_sec,
        ),
        (
            "Max receipt observed latency sec",
            summary.max_observed_latency_sec,
        ),
    ];

    for (index, (name, value)) in summary_rows.iter().enumerate() {
        let row = (index + 1) as u32;
        summary_sheet.write_string(row, 0, *name)?;
        summary_sheet.write_number_with_format(row, 1, *value, &decimal_format)?;
    }

    summary_sheet.set_column_width(0, 42)?;
    summary_sheet.set_column_width(1, 22)?;
    summary_sheet.set_freeze_panes(1, 0)?;

    workbook.save(Path::new(output_path))
}
