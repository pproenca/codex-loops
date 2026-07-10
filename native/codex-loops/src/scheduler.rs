use std::{
    env,
    net::{IpAddr, SocketAddr, TcpListener},
    time::Duration,
};

use percent_encoding::{AsciiSet, CONTROLS, utf8_percent_encode};
use reqwest::{Client, StatusCode};
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::{Value, json};
use url::Url;

use crate::error::{AppError, AppResult};

const PATH_SEGMENT: &AsciiSet = &CONTROLS
    .add(b' ')
    .add(b'"')
    .add(b'#')
    .add(b'%')
    .add(b'/')
    .add(b':')
    .add(b'<')
    .add(b'>')
    .add(b'?')
    .add(b'@')
    .add(b'[')
    .add(b'\\')
    .add(b']')
    .add(b'^')
    .add(b'`')
    .add(b'{')
    .add(b'|')
    .add(b'}');

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(transparent)]
pub struct RunId(String);

impl RunId {
    pub fn new(value: impl Into<String>) -> AppResult<Self> {
        let value = value.into();
        if value.is_empty() {
            Err(AppError::new(
                2,
                "run_id_invalid",
                "Run ID must be a non-empty string.",
            ))
        } else {
            Ok(Self(value))
        }
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl<'de> Deserialize<'de> for RunId {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        Self::new(value).map_err(serde::de::Error::custom)
    }
}

#[derive(Debug, Serialize, Deserialize)]
struct SchedulerSuccessEnvelope {
    api_version: String,
    data: Value,
}

#[derive(Debug, Serialize, Deserialize)]
struct SchedulerFailureEnvelope {
    api_version: String,
    error: SchedulerFailure,
}

#[derive(Debug, Serialize, Deserialize)]
struct SchedulerFailure {
    code: String,
    message: String,
    #[serde(default)]
    details: Value,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(untagged)]
enum SchedulerEnvelope {
    Success(SchedulerSuccessEnvelope),
    Failure(SchedulerFailureEnvelope),
}

impl SchedulerEnvelope {
    fn api_version(&self) -> &str {
        match self {
            Self::Success(envelope) => &envelope.api_version,
            Self::Failure(envelope) => &envelope.api_version,
        }
    }

    fn into_value(self) -> Value {
        serde_json::to_value(self).unwrap_or_else(|error| {
            json!({"api_version": "scheduler.v1", "error": {"code": "serialization_failed", "message": error.to_string()}})
        })
    }
}

#[derive(Debug)]
pub enum HealthState {
    Compatible(Value),
    Incompatible { found: String, envelope: Value },
    Unreachable { reason: String },
}

#[derive(Clone)]
pub struct SchedulerClient {
    http: Client,
    base_url: Url,
    managed: bool,
}

impl SchedulerClient {
    pub fn from_env() -> AppResult<Self> {
        if let Some(raw) = env::var("CODEX_LOOPS_SCHEDULER_URL")
            .ok()
            .filter(|value| !value.is_empty())
        {
            return Self::new(&raw);
        }
        let host = env::var("CODEX_LOOPS_SCHEDULER_HOST")
            .ok()
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| "127.0.0.1".into());
        let raw_port = env::var("CODEX_LOOPS_SCHEDULER_PORT")
            .ok()
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| "47125".into());
        let port = raw_port
            .parse::<u16>()
            .ok()
            .filter(|port| *port > 0)
            .ok_or_else(|| {
                AppError::new(
                    2,
                    "scheduler_port_invalid",
                    "CODEX_LOOPS_SCHEDULER_PORT must be a valid TCP port.",
                )
                .details(json!({"value": raw_port}))
            })?;
        Self::managed(&local_url(&host, port))
    }

    pub fn new(base_url: &str) -> AppResult<Self> {
        Self::build(base_url, false)
    }

    pub fn managed(base_url: &str) -> AppResult<Self> {
        Self::build(base_url, true)
    }

    pub fn managed_from_env() -> AppResult<Self> {
        let mut client = Self::from_env()?;
        client.managed = true;
        Ok(client)
    }

    fn build(base_url: &str, managed: bool) -> AppResult<Self> {
        let timeout = env::var("CODEX_LOOPS_SCHEDULER_REQUEST_TIMEOUT_MS")
            .ok()
            .and_then(|value| value.parse().ok())
            .filter(|value: &u64| *value > 0)
            .unwrap_or(5_000);
        let http = Client::builder()
            .timeout(Duration::from_millis(timeout))
            .build()
            .map_err(|error| AppError::new(6, "http_client_failed", error.to_string()))?;
        let mut base_url = Url::parse(base_url).map_err(|error| {
            AppError::new(2, "scheduler_url_invalid", "Invalid scheduler URL.")
                .details(json!({"url": base_url, "reason": error.to_string()}))
        })?;
        base_url.set_path("");
        base_url.set_query(None);
        base_url.set_fragment(None);
        Ok(Self {
            http,
            base_url,
            managed,
        })
    }

    pub fn base_url(&self) -> &Url {
        &self.base_url
    }

    pub fn is_managed(&self) -> bool {
        self.managed
    }

    pub fn is_local(&self) -> bool {
        if self.base_url.scheme() != "http" {
            return false;
        }
        self.base_url.host_str().is_some_and(|host| {
            let host = host.trim_matches(['[', ']']);
            if host == "localhost" || host.starts_with("127.") {
                return true;
            }
            host.parse::<IpAddr>().is_ok_and(|ip| {
                !ip.is_unspecified() && TcpListener::bind(SocketAddr::new(ip, 0)).map(drop).is_ok()
            })
        })
    }

    pub async fn health_state(&self) -> HealthState {
        let url = match self.base_url.join("/api/health") {
            Ok(url) => url,
            Err(error) => {
                return HealthState::Unreachable {
                    reason: error.to_string(),
                };
            }
        };
        let response = match self
            .http
            .get(url)
            .header("accept", "application/json")
            .send()
            .await
        {
            Ok(response) => response,
            Err(error) => {
                return HealthState::Unreachable {
                    reason: error.to_string(),
                };
            }
        };
        let status = response.status();
        let text = match response.text().await {
            Ok(text) => text,
            Err(error) => {
                return HealthState::Incompatible {
                    found: "unreadable".into(),
                    envelope: json!({"http_status": status.as_u16(), "reason": error.to_string()}),
                };
            }
        };
        let envelope: Value = match serde_json::from_str(&text) {
            Ok(value) => value,
            Err(error) => {
                return HealthState::Incompatible {
                    found: "non-json".into(),
                    envelope: json!({"http_status": status.as_u16(), "body": text, "reason": error.to_string()}),
                };
            }
        };
        let version = envelope
            .pointer("/data/version")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let compatible = status.is_success()
            && envelope.get("api_version").and_then(Value::as_str) == Some("scheduler.v1")
            && envelope.pointer("/data/status").and_then(Value::as_str) == Some("ok")
            && version == env!("CARGO_PKG_VERSION");
        if compatible {
            HealthState::Compatible(envelope)
        } else {
            HealthState::Incompatible {
                found: version.into(),
                envelope,
            }
        }
    }

    pub async fn validate(&self, script_path: &str) -> AppResult<Value> {
        self.scheduler_request(
            reqwest::Method::POST,
            "/api/workflows/validate",
            Some(json!({"script_path": script_path})),
        )
        .await
    }

    pub async fn start(&self, attrs: Value) -> AppResult<Value> {
        self.scheduler_request(reqwest::Method::POST, "/api/runs", Some(attrs))
            .await
    }

    pub async fn status(&self, run_id: &RunId) -> AppResult<Value> {
        self.scheduler_request(
            reqwest::Method::GET,
            &format!("/api/runs/{}", segment(run_id.as_str())),
            None,
        )
        .await
    }

    pub async fn inspect(&self, run_id: &RunId) -> AppResult<Value> {
        self.scheduler_request(
            reqwest::Method::GET,
            &format!("/api/runs/{}/events", segment(run_id.as_str())),
            None,
        )
        .await
    }

    pub async fn resume(&self, run_id: &RunId, attrs: Value) -> AppResult<Value> {
        self.scheduler_request(
            reqwest::Method::POST,
            &format!("/api/runs/{}/resume", segment(run_id.as_str())),
            Some(attrs),
        )
        .await
    }

    pub fn ui_url(&self, run_id: &RunId) -> String {
        format!(
            "{}/runs/{}",
            self.base_url.as_str().trim_end_matches('/'),
            segment(run_id.as_str())
        )
    }

    async fn scheduler_request(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<Value>,
    ) -> AppResult<Value> {
        let (status, envelope) = self.request_with_status(method, path, body).await?;
        if envelope.api_version() != "scheduler.v1" {
            return Err(unexpected(status, envelope.into_value()));
        }
        match envelope {
            SchedulerEnvelope::Success(envelope) if status.is_success() => {
                Ok(serde_json::to_value(envelope)
                    .map_err(|error| AppError::new(6, "scheduler_response", error.to_string()))?)
            }
            SchedulerEnvelope::Success(envelope) => Err(unexpected(
                status,
                serde_json::to_value(envelope).unwrap_or(Value::Null),
            )),
            SchedulerEnvelope::Failure(envelope) => {
                Err(
                    AppError::new(4, envelope.error.code, envelope.error.message)
                        .details(envelope.error.details)
                        .mcp_api_version("scheduler.v1"),
                )
            }
        }
    }

    async fn request_with_status(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<Value>,
    ) -> AppResult<(StatusCode, SchedulerEnvelope)> {
        let url = self.base_url.join(path).map_err(|error| {
            AppError::new(
                6,
                "scheduler_request_invalid",
                "Could not build scheduler request URL.",
            )
            .details(json!({"path": path, "reason": error.to_string()}))
        })?;
        let mut request = self
            .http
            .request(method, url)
            .header("accept", "application/json");
        if let Some(body) = body {
            request = request.json(&body);
        }
        let response = request.send().await.map_err(|error| {
            AppError::new(
                6,
                "scheduler_unavailable",
                "Could not reach the Codex Loops scheduler.",
            )
            .details(json!({"server": self.base_url.as_str(), "reason": error.to_string()}))
        })?;
        let status = response.status();
        let text = response.text().await.map_err(|error| {
            AppError::new(
                6,
                "scheduler_response",
                "Could not read scheduler response.",
            )
            .details(json!({"http_status": status.as_u16(), "reason": error.to_string()}))
        })?;
        let value = serde_json::from_str(&text).map_err(|error| {
            AppError::new(
                6,
                "scheduler_response",
                "Scheduler returned a non-JSON response.",
            )
            .details(
                json!({"http_status": status.as_u16(), "body": text, "reason": error.to_string()}),
            )
        })?;
        Ok((status, value))
    }
}

pub fn local_url(host: &str, port: u16) -> String {
    let host = if host.contains(':') && !host.starts_with('[') {
        format!("[{host}]")
    } else {
        host.into()
    };
    format!("http://{host}:{port}")
}

fn unexpected(status: StatusCode, payload: Value) -> AppError {
    AppError::new(
        6,
        "scheduler_response",
        "Scheduler returned an unexpected response.",
    )
    .details(json!({"http_status": status.as_u16(), "payload": payload}))
}

fn segment(value: &str) -> String {
    utf8_percent_encode(value, PATH_SEGMENT).to_string()
}

#[cfg(test)]
mod tests {
    use std::{
        io::{Read, Write},
        net::TcpListener,
        thread,
    };

    use super::*;

    fn one_response(status: &str, body: &str) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let status = status.to_owned();
        let body = body.to_owned();
        thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0_u8; 8_192];
            let _ = stream.read(&mut request);
            write!(
                stream,
                "HTTP/1.1 {status}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                body.len()
            )
            .unwrap();
        });
        format!("http://{address}")
    }

    #[test]
    fn path_segments_are_encoded_without_losing_route_safe_characters() {
        assert_eq!(segment("run_1-safe"), "run_1-safe");
        assert_eq!(segment("mcp:run/one"), "mcp%3Arun%2Fone");
    }

    #[test]
    fn local_urls_support_ipv4_and_ipv6() {
        assert_eq!(local_url("127.0.0.1", 47_125), "http://127.0.0.1:47125");
        assert_eq!(local_url("::1", 47_125), "http://[::1]:47125");
    }

    #[test]
    fn local_scheduler_detection_is_fail_closed() {
        assert!(
            SchedulerClient::new("http://127.0.0.1:47125")
                .unwrap()
                .is_local()
        );
        assert!(
            SchedulerClient::new("http://[::1]:47125")
                .unwrap()
                .is_local()
        );
        assert!(
            !SchedulerClient::new("https://127.0.0.1:47125")
                .unwrap()
                .is_local()
        );
        assert!(
            !SchedulerClient::new("http://example.com:47125")
                .unwrap()
                .is_local()
        );
    }

    #[tokio::test]
    async fn scheduler_errors_keep_the_api_code_and_details() {
        let url = one_response(
            "404 Not Found",
            r#"{"api_version":"scheduler.v1","error":{"code":"run_not_found","message":"No such run.","details":{"run_id":"missing"}}}"#,
        );
        let error = SchedulerClient::new(&url)
            .unwrap()
            .status("missing")
            .await
            .unwrap_err();
        assert_eq!(error.status, 4);
        assert_eq!(error.code.as_ref(), "run_not_found");
        assert_eq!(error.details["run_id"], "missing");
    }

    #[tokio::test]
    async fn malformed_scheduler_responses_are_typed_and_diagnostic() {
        let url = one_response("502 Bad Gateway", "not json");
        let error = SchedulerClient::new(&url)
            .unwrap()
            .status("run-1")
            .await
            .unwrap_err();
        assert_eq!(error.status, 6);
        assert_eq!(error.code.as_ref(), "scheduler_response");
        assert_eq!(error.details["http_status"], 502);
        assert_eq!(error.details["body"], "not json");
    }

    #[tokio::test]
    async fn health_rejects_a_scheduler_from_another_version() {
        let url = one_response(
            "200 OK",
            r#"{"api_version":"scheduler.v1","data":{"status":"ok","version":"9.9.9"}}"#,
        );
        match SchedulerClient::new(&url).unwrap().health_state().await {
            HealthState::Incompatible { found, envelope } => {
                assert_eq!(found, "9.9.9");
                assert_eq!(envelope["data"]["status"], "ok");
            }
            state => panic!("expected incompatible scheduler, got {state:?}"),
        }
    }
}
