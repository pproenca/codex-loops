use std::{
    env,
    net::IpAddr,
    num::{NonZeroU16, NonZeroU64},
    time::Duration,
};

use percent_encoding::{AsciiSet, CONTROLS, utf8_percent_encode};
use reqwest::{Client, StatusCode};
use serde::{Serialize, de::DeserializeOwned};
use serde_json::{Value, json};
use url::Url;

use crate::error::{AppError, AppResult, ExitStatus};

mod contracts;
use contracts::{HealthEnvelope, SchedulerEnvelope};
pub use contracts::{
    Provider, ResumeRequest, RunId, SchedulerDocument, SchedulerResponse, StartData, StartRequest,
    WorkflowLocationRequest,
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
    Incompatible {
        found: Option<String>,
        envelope: Value,
    },
    Unreachable {
        reason: String,
    },
}

impl std::fmt::Display for HealthState {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Compatible(_) => formatter.write_str("compatible"),
            Self::Incompatible {
                found: Some(found), ..
            } => write!(formatter, "incompatible ({found})"),
            Self::Incompatible { found: None, .. } => formatter.write_str("incompatible"),
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
    pub fn from_env() -> AppResult<Self> {
        if let Some(raw) = optional_env("CODEX_LOOPS_SCHEDULER_URL")? {
            return Self::new(&raw);
        }
        let host =
            optional_env("CODEX_LOOPS_SCHEDULER_HOST")?.unwrap_or_else(|| "127.0.0.1".into());
        let raw_port =
            optional_env("CODEX_LOOPS_SCHEDULER_PORT")?.unwrap_or_else(|| "47125".into());
        let port = raw_port.parse::<NonZeroU16>().map_err(|error| {
            AppError::scheduler(
                ExitStatus::Usage,
                "scheduler_port_invalid",
                "CODEX_LOOPS_SCHEDULER_PORT must be a valid TCP port.",
            )
            .details(json!({"value": raw_port, "reason": error.to_string()}))
        })?;
        Self::managed(&local_url(&host, port))
    }

    pub fn new(base_url: &str) -> AppResult<Self> {
        Self::build(base_url, Management::External)
    }

    pub fn managed(base_url: &str) -> AppResult<Self> {
        Self::build(base_url, Management::Managed)
    }

    pub fn managed_from_env() -> AppResult<Self> {
        let mut client = Self::from_env()?;
        client.management = Management::Managed;
        Ok(client)
    }

    fn build(base_url: &str, management: Management) -> AppResult<Self> {
        let timeout = optional_env("CODEX_LOOPS_SCHEDULER_REQUEST_TIMEOUT_MS")?
            .map(|value| {
                value.parse::<NonZeroU64>().map_err(|error| {
                    AppError::scheduler(
                        ExitStatus::Usage,
                        "scheduler_timeout_invalid",
                        "CODEX_LOOPS_SCHEDULER_REQUEST_TIMEOUT_MS must be a positive integer.",
                    )
                    .details(json!({"value": value, "reason": error.to_string()}))
                })
            })
            .transpose()?
            .map_or(5_000, NonZeroU64::get);
        let http = Client::builder()
            .timeout(Duration::from_millis(timeout))
            .build()
            .map_err(|error| {
                AppError::scheduler(ExitStatus::Runtime, "http_client_failed", error.to_string())
            })?;
        let mut base_url = Url::parse(base_url).map_err(|error| {
            AppError::scheduler(
                ExitStatus::Usage,
                "scheduler_url_invalid",
                "Invalid scheduler URL.",
            )
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
        if self.management == Management::Managed {
            return true;
        }
        if self.base_url.scheme() != "http" {
            return false;
        }
        self.base_url.host_str().is_some_and(|host| {
            let host = host.trim_matches(['[', ']']);
            host == "localhost" || host.parse::<IpAddr>().is_ok_and(|ip| ip.is_loopback())
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
                    found: None,
                    envelope: json!({"http_status": status.as_u16(), "reason": error.to_string()}),
                };
            }
        };
        let envelope: HealthEnvelope = match serde_json::from_str(&text) {
            Ok(value) => value,
            Err(error) => {
                return HealthState::Incompatible {
                    found: None,
                    envelope: json!({"http_status": status.as_u16(), "body": text, "reason": error.to_string()}),
                };
            }
        };
        let HealthEnvelope {
            api_version,
            data:
                contracts::HealthData {
                    status: health_status,
                    version,
                },
        } = envelope;
        let compatible = status.is_success()
            && api_version == "scheduler.v1"
            && health_status == "ok"
            && version == env!("CARGO_PKG_VERSION");
        let wire = json!({
            "api_version": &api_version,
            "data": {"status": &health_status, "version": &version}
        });
        if compatible {
            HealthState::Compatible(wire)
        } else {
            HealthState::Incompatible {
                found: Some(version),
                envelope: wire,
            }
        }
    }

    pub async fn require_compatible(&self) -> AppResult<()> {
        match self.health_state().await {
            HealthState::Compatible(_envelope) => Ok(()),
            HealthState::Incompatible { found, envelope } => {
                let message = match &found {
                    Some(found) => format!(
                        "A scheduler from another Codex Loops version is running (control plane {}, scheduler {found}).",
                        env!("CARGO_PKG_VERSION")
                    ),
                    None => "The configured endpoint is not a compatible Codex Loops scheduler."
                        .to_owned(),
                };
                Err(AppError::scheduler(
                    ExitStatus::Runtime,
                    "scheduler_version_mismatch",
                    message,
                )
                .details(json!({
                    "expected": env!("CARGO_PKG_VERSION"),
                    "found": found,
                    "health": envelope
                })))
            }
            HealthState::Unreachable { reason } => Err(AppError::scheduler(
                ExitStatus::Runtime,
                "scheduler_unavailable",
                "Could not reach the Codex Loops scheduler. Start it explicitly with `codex-loops serve`.",
            )
            .details(json!({"server": self.base_url.as_str(), "reason": reason}))
            .next_steps(["Run `codex-loops serve`, then retry the MCP tool call."])),
        }
    }

    pub async fn validate(
        &self,
        script_path: &str,
    ) -> AppResult<SchedulerResponse<SchedulerDocument>> {
        self.scheduler_request(
            reqwest::Method::POST,
            "/api/workflows/validate",
            Some(json!({"script_path": script_path})),
        )
        .await
    }

    pub async fn start(&self, request: &StartRequest) -> AppResult<SchedulerResponse<StartData>> {
        self.scheduler_request(
            reqwest::Method::POST,
            "/api/runs",
            Some(request_body(request)?),
        )
        .await
    }

    pub async fn status(&self, run_id: &RunId) -> AppResult<SchedulerResponse<SchedulerDocument>> {
        self.scheduler_request(
            reqwest::Method::GET,
            &format!("/api/runs/{}", segment(run_id.as_str())),
            None,
        )
        .await
    }

    pub async fn inspect(&self, run_id: &RunId) -> AppResult<SchedulerResponse<SchedulerDocument>> {
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
    ) -> AppResult<SchedulerResponse<SchedulerDocument>> {
        self.scheduler_request(
            reqwest::Method::POST,
            &format!("/api/runs/{}/resume", segment(run_id.as_str())),
            Some(request_body(request)?),
        )
        .await
    }

    pub fn ui_url(&self, run_id: &RunId) -> Url {
        let mut url = self.base_url.clone();
        url.set_path(&format!("/runs/{}", segment(run_id.as_str())));
        url
    }

    async fn scheduler_request<T>(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<Value>,
    ) -> AppResult<SchedulerResponse<T>>
    where
        T: DeserializeOwned + Serialize,
    {
        let reply = self.request_with_status(method, path, body).await?;
        let status = reply.status;
        let envelope = reply.envelope;
        if envelope.api_version() != "scheduler.v1" {
            return Err(unexpected(status, envelope.into_wire_value()?));
        }
        match envelope {
            SchedulerEnvelope::Success(envelope) if status.is_success() => Ok(envelope),
            SchedulerEnvelope::Success(envelope) => {
                Err(unexpected(status, envelope.into_wire_value()?))
            }
            SchedulerEnvelope::Failure(envelope) => Err(AppError::scheduler(
                ExitStatus::Conflict,
                envelope.error.code,
                envelope.error.message,
            )
            .details(envelope.error.details)),
        }
    }

    async fn request_with_status<T>(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<Value>,
    ) -> AppResult<SchedulerReply<T>>
    where
        T: DeserializeOwned,
    {
        let url = self.base_url.join(path).map_err(|error| {
            AppError::scheduler(
                ExitStatus::Runtime,
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
            AppError::scheduler(
                ExitStatus::Runtime,
                "scheduler_unavailable",
                "Could not reach the Codex Loops scheduler.",
            )
            .details(json!({"server": self.base_url.as_str(), "reason": error.to_string()}))
        })?;
        let status = response.status();
        let text = response.text().await.map_err(|error| {
            AppError::scheduler(
                ExitStatus::Runtime,
                "scheduler_response",
                "Could not read scheduler response.",
            )
            .details(json!({"http_status": status.as_u16(), "reason": error.to_string()}))
        })?;
        let value = serde_json::from_str(&text).map_err(|error| {
            AppError::scheduler(
                ExitStatus::Runtime,
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

pub fn local_url(host: &str, port: NonZeroU16) -> String {
    let host = if host.contains(':') && !host.starts_with('[') {
        format!("[{host}]")
    } else {
        host.into()
    };
    format!("http://{host}:{port}")
}

fn unexpected(status: StatusCode, payload: Value) -> AppError {
    AppError::scheduler(
        ExitStatus::Runtime,
        "scheduler_response",
        "Scheduler returned an unexpected response.",
    )
    .details(json!({"http_status": status.as_u16(), "payload": payload}))
}

fn request_body(request: impl Serialize) -> AppResult<Value> {
    serde_json::to_value(request).map_err(|error| {
        AppError::scheduler(
            ExitStatus::Runtime,
            "scheduler_request_invalid",
            error.to_string(),
        )
    })
}

fn optional_env(name: &str) -> AppResult<Option<String>> {
    match env::var(name) {
        Ok(value) if value.is_empty() => Ok(None),
        Ok(value) => Ok(Some(value)),
        Err(env::VarError::NotPresent) => Ok(None),
        Err(env::VarError::NotUnicode(value)) => Err(AppError::scheduler(
            ExitStatus::Usage,
            "scheduler_environment_invalid",
            format!("{name} must contain valid Unicode."),
        )
        .details(json!({"variable": name, "value": value.to_string_lossy()}))),
    }
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

    fn one_response(status: &str, body: &str) -> (String, thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let status = status.to_owned();
        let body = body.to_owned();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0_u8; 8_192];
            let bytes_read = stream.read(&mut request).unwrap();
            assert!(bytes_read > 0);
            write!(
                stream,
                "HTTP/1.1 {status}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                body.len()
            )
            .unwrap();
        });
        (format!("http://{address}"), server)
    }

    #[test]
    fn path_segments_are_encoded_without_losing_route_safe_characters() {
        assert_eq!(segment("run_1-safe"), "run_1-safe");
        assert_eq!(segment("mcp:run/one"), "mcp%3Arun%2Fone");

        let client = SchedulerClient::new("http://127.0.0.1:47125").unwrap();
        let run_id = RunId::new("mcp:run").unwrap();
        assert_eq!(
            client.ui_url(&run_id).as_str(),
            "http://127.0.0.1:47125/runs/mcp%3Arun"
        );
    }

    #[test]
    fn local_urls_support_ipv4_and_ipv6() {
        let port = NonZeroU16::new(47_125).unwrap();
        assert_eq!(local_url("127.0.0.1", port), "http://127.0.0.1:47125");
        assert_eq!(local_url("::1", port), "http://[::1]:47125");
    }

    #[test]
    fn start_request_omits_absent_optional_fields() {
        let value = serde_json::to_value(StartRequest {
            script_path: "/tmp/workflow.exs".into(),
            workspace_root: "/tmp".into(),
            run_id: None,
            provider: None,
            budget: None,
        })
        .unwrap();

        assert_eq!(
            value,
            json!({"script_path": "/tmp/workflow.exs", "workspace_root": "/tmp"})
        );

        let value = serde_json::to_value(StartRequest {
            script_path: "/tmp/workflow.exs".into(),
            workspace_root: "/tmp".into(),
            run_id: None,
            provider: Some(Provider::Mock),
            budget: Some(0),
        })
        .unwrap();
        assert_eq!(
            value,
            json!({
                "script_path": "/tmp/workflow.exs",
                "workspace_root": "/tmp",
                "provider": "mock",
                "budget": 0
            })
        );
    }

    #[test]
    fn resume_request_keeps_script_and_workspace_root_atomic() {
        let value = serde_json::to_value(ResumeRequest {
            workflow: Some(WorkflowLocationRequest {
                script_path: "/tmp/workflow.exs".into(),
                workspace_root: "/tmp".into(),
            }),
            provider: Some(Provider::Mock),
        })
        .unwrap();

        assert_eq!(
            value,
            json!({
                "script_path": "/tmp/workflow.exs",
                "workspace_root": "/tmp",
                "provider": "mock"
            })
        );

        let value = serde_json::to_value(ResumeRequest {
            workflow: None,
            provider: Some(Provider::Mock),
        })
        .unwrap();

        assert_eq!(value, json!({"provider": "mock"}));
    }

    #[test]
    fn run_ids_enforce_the_scheduler_route_grammar() {
        assert!(RunId::new("run-1.alpha:2").is_ok());
        assert!(RunId::new("-leading-dash").is_err());
        assert!(RunId::new("contains/slash").is_err());
        assert!(RunId::new("contains space").is_err());
        assert_eq!("run-1".parse::<RunId>().unwrap().as_str(), "run-1");
        assert_eq!("mock".parse::<Provider>().unwrap(), Provider::Mock);
        assert!("other".parse::<Provider>().is_err());
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
        assert!(
            !SchedulerClient::new("http://192.168.1.10:47125")
                .unwrap()
                .is_local()
        );
        assert!(
            SchedulerClient::managed("http://0.0.0.0:47125")
                .unwrap()
                .is_local()
        );
    }

    #[tokio::test]
    async fn scheduler_errors_keep_the_api_code_and_details() {
        let (url, server) = one_response(
            "404 Not Found",
            r#"{"api_version":"scheduler.v1","error":{"code":"run_not_found","message":"No such run.","details":{"run_id":"missing"}}}"#,
        );
        let error = SchedulerClient::new(&url)
            .unwrap()
            .status(&RunId::new("missing").unwrap())
            .await
            .unwrap_err();
        server.join().unwrap();
        assert_eq!(error.status(), ExitStatus::Conflict);
        assert_eq!(error.code(), "run_not_found");
        assert_eq!(error.diagnostic()["details"]["run_id"], "missing");
        assert_eq!(error.mcp_envelope()["api_version"], "scheduler.v1");
    }

    #[tokio::test]
    async fn malformed_scheduler_responses_are_typed_and_diagnostic() {
        let (url, server) = one_response("502 Bad Gateway", "not json");
        let error = SchedulerClient::new(&url)
            .unwrap()
            .status(&RunId::new("run-1").unwrap())
            .await
            .unwrap_err();
        server.join().unwrap();
        assert_eq!(error.status(), ExitStatus::Runtime);
        assert_eq!(error.code(), "scheduler_response");
        assert_eq!(error.diagnostic()["details"]["http_status"], 502);
        assert_eq!(error.diagnostic()["details"]["body"], "not json");
    }

    #[tokio::test]
    async fn health_rejects_a_scheduler_from_another_version() {
        let (url, server) = one_response(
            "200 OK",
            r#"{"api_version":"scheduler.v1","data":{"status":"ok","version":"9.9.9"}}"#,
        );
        let state = SchedulerClient::new(&url).unwrap().health_state().await;
        server.join().unwrap();
        match state {
            HealthState::Incompatible { found, envelope } => {
                assert_eq!(found.as_deref(), Some("9.9.9"));
                assert_eq!(envelope["data"]["status"], "ok");
            }
            state => panic!("expected incompatible scheduler, got {state:?}"),
        }
    }

    #[tokio::test]
    async fn malformed_health_has_no_fake_version() {
        let (url, server) = one_response("502 Bad Gateway", "not json");
        let state = SchedulerClient::new(&url).unwrap().health_state().await;
        server.join().unwrap();

        assert!(matches!(
            state,
            HealthState::Incompatible { found: None, .. }
        ));
    }
}
