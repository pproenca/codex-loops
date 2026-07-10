use std::{
    env,
    net::{IpAddr, SocketAddr, TcpListener},
    time::Duration,
};

use percent_encoding::{AsciiSet, CONTROLS, utf8_percent_encode};
use reqwest::{Client, StatusCode};
use serde::{Serialize, de::DeserializeOwned};
use serde_json::{Value, json};
use url::Url;

use crate::error::{ErrorContext, SchedulerError, SchedulerResult};

mod contracts;
use contracts::{HealthEnvelope, SchedulerEnvelope};
pub use contracts::{
    ResumeRequest, RunId, SchedulerDocument, SchedulerResponse, StartData, StartRequest,
};

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

#[derive(Debug)]
pub enum HealthState {
    Compatible(Value),
    Incompatible { found: String, envelope: Value },
    Unreachable { reason: String },
}

impl std::fmt::Display for HealthState {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Compatible(_envelope) => formatter.write_str("compatible"),
            Self::Incompatible { found, .. } => write!(formatter, "incompatible ({found})"),
            Self::Unreachable { reason } => write!(formatter, "unreachable ({reason})"),
        }
    }
}

#[derive(Clone)]
pub struct SchedulerClient {
    http: Client,
    base_url: Url,
    management: Management,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Management {
    External,
    Managed,
}

impl SchedulerClient {
    pub fn from_env() -> SchedulerResult<Self> {
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
                SchedulerError::new(
                    2,
                    "scheduler_port_invalid",
                    "CODEX_LOOPS_SCHEDULER_PORT must be a valid TCP port.",
                )
                .details(json!({"value": raw_port}))
            })?;
        Self::managed(&local_url(&host, port))
    }

    pub fn new(base_url: &str) -> SchedulerResult<Self> {
        Self::build(base_url, Management::External)
    }

    pub fn managed(base_url: &str) -> SchedulerResult<Self> {
        Self::build(base_url, Management::Managed)
    }

    pub fn managed_from_env() -> SchedulerResult<Self> {
        let mut client = Self::from_env()?;
        client.management = Management::Managed;
        Ok(client)
    }

    fn build(base_url: &str, management: Management) -> SchedulerResult<Self> {
        let timeout = env::var("CODEX_LOOPS_SCHEDULER_REQUEST_TIMEOUT_MS")
            .ok()
            .and_then(|value| value.parse().ok())
            .filter(|value: &u64| *value > 0)
            .unwrap_or(5_000);
        let http = Client::builder()
            .timeout(Duration::from_millis(timeout))
            .build()
            .map_err(|error| SchedulerError::new(6, "http_client_failed", error.to_string()))?;
        let mut base_url = Url::parse(base_url).map_err(|error| {
            SchedulerError::new(2, "scheduler_url_invalid", "Invalid scheduler URL.")
                .details(json!({"url": base_url, "reason": error.to_string()}))
        })?;
        base_url.set_path("");
        base_url.set_query(None);
        base_url.set_fragment(None);
        Ok(Self {
            http,
            base_url,
            management,
        })
    }

    pub fn base_url(&self) -> &Url {
        &self.base_url
    }

    pub fn is_managed(&self) -> bool {
        self.management == Management::Managed
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
        let envelope: HealthEnvelope = match serde_json::from_str(&text) {
            Ok(value) => value,
            Err(error) => {
                return HealthState::Incompatible {
                    found: "non-json".into(),
                    envelope: json!({"http_status": status.as_u16(), "body": text, "reason": error.to_string()}),
                };
            }
        };
        let version = envelope.data.version.clone();
        let compatible = status.is_success()
            && envelope.api_version == "scheduler.v1"
            && envelope.data.status == "ok"
            && version == env!("CARGO_PKG_VERSION");
        let wire = serde_json::to_value(envelope)
            .unwrap_or_else(|error| json!({"api_version": "invalid", "reason": error.to_string()}));
        if compatible {
            HealthState::Compatible(wire)
        } else {
            HealthState::Incompatible {
                found: version,
                envelope: wire,
            }
        }
    }

    pub async fn validate(
        &self,
        script_path: &str,
    ) -> SchedulerResult<SchedulerResponse<SchedulerDocument>> {
        self.scheduler_request(
            reqwest::Method::POST,
            "/api/workflows/validate",
            Some(json!({"script_path": script_path})),
        )
        .await
    }

    pub async fn start(
        &self,
        request: &StartRequest,
    ) -> SchedulerResult<SchedulerResponse<StartData>> {
        self.scheduler_request(
            reqwest::Method::POST,
            "/api/runs",
            Some(serde_json::to_value(request).map_err(|error| {
                SchedulerError::new(6, "scheduler_request_invalid", error.to_string())
            })?),
        )
        .await
    }

    pub async fn status(
        &self,
        run_id: &RunId,
    ) -> SchedulerResult<SchedulerResponse<SchedulerDocument>> {
        self.scheduler_request(
            reqwest::Method::GET,
            &format!("/api/runs/{}", segment(run_id.as_str())),
            None,
        )
        .await
    }

    pub async fn inspect(
        &self,
        run_id: &RunId,
    ) -> SchedulerResult<SchedulerResponse<SchedulerDocument>> {
        self.scheduler_request(
            reqwest::Method::GET,
            &format!("/api/runs/{}/events", segment(run_id.as_str())),
            None,
        )
        .await
    }

    pub async fn resume(
        &self,
        run_id: &RunId,
        request: &ResumeRequest,
    ) -> SchedulerResult<SchedulerResponse<SchedulerDocument>> {
        self.scheduler_request(
            reqwest::Method::POST,
            &format!("/api/runs/{}/resume", segment(run_id.as_str())),
            Some(serde_json::to_value(request).map_err(|error| {
                SchedulerError::new(6, "scheduler_request_invalid", error.to_string())
            })?),
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

    async fn scheduler_request<T>(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<Value>,
    ) -> SchedulerResult<SchedulerResponse<T>>
    where
        T: DeserializeOwned + Serialize,
    {
        let reply = self.request_with_status(method, path, body).await?;
        let status = reply.status;
        let envelope = reply.envelope;
        if envelope.api_version() != "scheduler.v1" {
            return Err(unexpected(status, envelope.into_value()));
        }
        match envelope {
            SchedulerEnvelope::Success(envelope) if status.is_success() => Ok(envelope),
            SchedulerEnvelope::Success(envelope) => Err(unexpected(
                status,
                serde_json::to_value(envelope).unwrap_or(Value::Null),
            )),
            SchedulerEnvelope::Failure(envelope) => {
                Err(
                    SchedulerError::new(4, envelope.error.code, envelope.error.message)
                        .details(envelope.error.details),
                )
            }
        }
    }

    async fn request_with_status<T>(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<Value>,
    ) -> SchedulerResult<SchedulerReply<T>>
    where
        T: DeserializeOwned,
    {
        let url = self.base_url.join(path).map_err(|error| {
            SchedulerError::new(
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
            SchedulerError::new(
                6,
                "scheduler_unavailable",
                "Could not reach the Codex Loops scheduler.",
            )
            .details(json!({"server": self.base_url.as_str(), "reason": error.to_string()}))
        })?;
        let status = response.status();
        let text = response.text().await.map_err(|error| {
            SchedulerError::new(
                6,
                "scheduler_response",
                "Could not read scheduler response.",
            )
            .details(json!({"http_status": status.as_u16(), "reason": error.to_string()}))
        })?;
        let value = serde_json::from_str(&text).map_err(|error| {
            SchedulerError::new(
                6,
                "scheduler_response",
                "Scheduler returned a non-JSON response.",
            )
            .details(
                json!({"http_status": status.as_u16(), "body": text, "reason": error.to_string()}),
            )
        })?;
        Ok(SchedulerReply {
            status,
            envelope: value,
        })
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

fn unexpected(status: StatusCode, payload: Value) -> SchedulerError {
    SchedulerError::new(
        6,
        "scheduler_response",
        "Scheduler returned an unexpected response.",
    )
    .details(json!({"http_status": status.as_u16(), "payload": payload}))
}

struct SchedulerReply<T> {
    status: StatusCode,
    envelope: SchedulerEnvelope<T>,
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
    fn start_request_omits_absent_optional_fields() {
        let value = serde_json::to_value(StartRequest {
            script_path: "/tmp/workflow.exs".into(),
            run_id: None,
            provider: None,
            budget: None,
        })
        .unwrap();

        assert_eq!(value, json!({"script_path": "/tmp/workflow.exs"}));
    }

    #[test]
    fn run_ids_enforce_the_scheduler_route_grammar() {
        assert!(RunId::new("run-1.alpha:2").is_ok());
        assert!(RunId::new("-leading-dash").is_err());
        assert!(RunId::new("contains/slash").is_err());
        assert!(RunId::new("contains space").is_err());
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
            .status(&RunId::new("missing").unwrap())
            .await
            .unwrap_err();
        assert_eq!(error.status(), 4);
        assert_eq!(error.code(), "run_not_found");
        assert_eq!(error.diagnostic()["details"]["run_id"], "missing");
    }

    #[tokio::test]
    async fn malformed_scheduler_responses_are_typed_and_diagnostic() {
        let url = one_response("502 Bad Gateway", "not json");
        let error = SchedulerClient::new(&url)
            .unwrap()
            .status(&RunId::new("run-1").unwrap())
            .await
            .unwrap_err();
        assert_eq!(error.status(), 6);
        assert_eq!(error.code(), "scheduler_response");
        assert_eq!(error.diagnostic()["details"]["http_status"], 502);
        assert_eq!(error.diagnostic()["details"]["body"], "not json");
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
