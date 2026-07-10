use std::{
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};

use rmcp::{
    ErrorData as McpError, RoleServer, ServerHandler, ServiceExt,
    model::{
        CallToolRequestParams, CallToolResult, JsonObject, ListToolsResult, PaginatedRequestParams,
        ServerCapabilities, ServerInfo, Tool, object,
    },
    service::RequestContext,
    transport::stdio,
};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use crate::{
    cli::{require_shared_filesystem, resolve_script_from},
    error::{AppError, AppResult},
    lifecycle,
    scheduler::{RunId, SchedulerClient},
};

#[derive(Clone)]
struct CodexLoopsServer {
    client: SchedulerClient,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
enum Provider {
    Mock,
    Codex,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct ValidateArgs {
    script_path: PathBuf,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct StartArgs {
    script_path: PathBuf,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    run_id: Option<RunId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    provider: Option<Provider>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    budget: Option<u64>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RunArgs {
    run_id: RunId,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct ResumeArgs {
    run_id: RunId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    script_path: Option<PathBuf>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    script: Option<PathBuf>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    provider: Option<Provider>,
}

#[derive(Debug)]
enum ToolCall {
    Validate(ValidateArgs),
    Start(StartArgs),
    Status(RunArgs),
    Inspect(RunArgs),
    Resume(ResumeArgs),
    OpenUi(RunArgs),
}

impl ToolCall {
    fn parse(name: &str, arguments: JsonObject) -> AppResult<Self> {
        let value = Value::Object(arguments);
        let parsed = match name {
            "workflow_validate" => serde_json::from_value(value).map(Self::Validate),
            "workflow_start" => serde_json::from_value(value).map(Self::Start),
            "workflow_status" => serde_json::from_value(value).map(Self::Status),
            "workflow_inspect" => serde_json::from_value(value).map(Self::Inspect),
            "workflow_resume" => serde_json::from_value(value).map(Self::Resume),
            "workflow_open_ui" => serde_json::from_value(value).map(Self::OpenUi),
            unknown => {
                return Err(AppError::new(
                    2,
                    "unknown_tool",
                    format!("Unknown tool: {unknown}"),
                ));
            }
        }
        .map_err(|error| invalid_args(name, error.to_string()))?;
        parsed.validate(name)?;
        Ok(parsed)
    }

    fn validate(&self, name: &str) -> AppResult<()> {
        let invalid = match self {
            Self::Validate(args) if args.script_path.as_os_str().is_empty() => Some("script_path"),
            Self::Start(args) if args.script_path.as_os_str().is_empty() => Some("script_path"),
            Self::Resume(args)
                if args
                    .script_path
                    .as_ref()
                    .is_some_and(|path| path.as_os_str().is_empty()) =>
            {
                Some("script_path")
            }
            Self::Resume(args)
                if args
                    .script
                    .as_ref()
                    .is_some_and(|path| path.as_os_str().is_empty()) =>
            {
                Some("script")
            }
            Self::Validate(_)
            | Self::Start(_)
            | Self::Status(_)
            | Self::Inspect(_)
            | Self::Resume(_)
            | Self::OpenUi(_) => None,
        };
        match invalid {
            Some(field) => Err(invalid_args(
                name,
                format!("{field} must be a non-empty string"),
            )),
            None => Ok(()),
        }
    }

    fn contains_relative_script_path(&self) -> bool {
        match self {
            Self::Validate(args) => !args.script_path.is_absolute(),
            Self::Start(args) => !args.script_path.is_absolute(),
            Self::Resume(args) => args
                .script_path
                .iter()
                .chain(args.script.iter())
                .any(|path| !path.is_absolute()),
            Self::Status(_args) | Self::Inspect(_args) | Self::OpenUi(_args) => false,
        }
    }

    fn requires_shared_filesystem(&self) -> bool {
        match self {
            Self::Validate(_) | Self::Start(_) => true,
            Self::Resume(args) => args.script_path.is_some() || args.script.is_some(),
            Self::Status(_args) | Self::Inspect(_args) | Self::OpenUi(_args) => false,
        }
    }

    fn resolve_scripts(&mut self, workspace_root: Option<&Path>) -> AppResult<()> {
        match self {
            Self::Validate(args) => {
                args.script_path = resolve_script_from(&args.script_path, workspace_root)?;
            }
            Self::Start(args) => {
                args.script_path = resolve_script_from(&args.script_path, workspace_root)?;
            }
            Self::Resume(args) => {
                args.script_path = args
                    .script_path
                    .take()
                    .map(|path| resolve_script_from(&path, workspace_root))
                    .transpose()?;
                args.script = args
                    .script
                    .take()
                    .map(|path| resolve_script_from(&path, workspace_root))
                    .transpose()?;
            }
            Self::Status(_args) | Self::Inspect(_args) | Self::OpenUi(_args) => {}
        }
        Ok(())
    }
}

impl CodexLoopsServer {
    fn new() -> AppResult<Self> {
        Ok(Self {
            client: SchedulerClient::from_env()?,
        })
    }

    async fn execute(&self, call: ToolCall) -> CallToolResult {
        if call.requires_shared_filesystem()
            && let Err(error) = require_shared_filesystem(&self.client)
        {
            return structured_error(error.mcp_envelope());
        }
        if let Err(error) = lifecycle::ensure_ready(&self.client).await {
            return structured_error(error.mcp_envelope());
        }

        let result: AppResult<Value> = match call {
            ToolCall::Validate(args) => self
                .client
                .validate(&args.script_path.to_string_lossy())
                .await
                .map_err(AppError::from),
            ToolCall::Start(args) => match serde_json::to_value(args) {
                Ok(value) => self.client.start(value).await.map_err(AppError::from),
                Err(error) => Err(invalid_args("workflow_start", error.to_string())),
            },
            ToolCall::Status(args) => self
                .client
                .status(&args.run_id)
                .await
                .map(conform_projection)
                .map_err(AppError::from),
            ToolCall::Inspect(args) => self
                .client
                .inspect(&args.run_id)
                .await
                .map(conform_projection)
                .map_err(AppError::from),
            ToolCall::Resume(args) => {
                let run_id = args.run_id.clone();
                match serde_json::to_value(args) {
                    Ok(mut value) => {
                        if let Some(object) = value.as_object_mut() {
                            object.remove("run_id");
                        }
                        self.client
                            .resume(&run_id, value)
                            .await
                            .map_err(AppError::from)
                    }
                    Err(error) => Err(invalid_args("workflow_resume", error.to_string())),
                }
            }
            ToolCall::OpenUi(args) => self
                .client
                .status(&args.run_id)
                .await
                .map(|envelope| open_ui_envelope(envelope, &self.client))
                .map_err(AppError::from),
        };
        match result {
            Ok(value) => CallToolResult::structured(value),
            Err(error) => structured_error(error.mcp_envelope()),
        }
    }
}

impl ServerHandler for CodexLoopsServer {
    fn get_info(&self) -> ServerInfo {
        ServerInfo::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(rmcp::model::Implementation::new("codex-loops", env!("CARGO_PKG_VERSION")))
            .with_instructions("Validate, start, inspect, resume, and open Codex Loops workflows through the local scheduler.")
    }

    async fn list_tools(
        &self,
        _request: Option<PaginatedRequestParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<ListToolsResult, McpError> {
        Ok(ListToolsResult::with_all_items(tools()))
    }

    async fn call_tool(
        &self,
        request: CallToolRequestParams,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, McpError> {
        let mut call = ToolCall::parse(&request.name, request.arguments.unwrap_or_default())
            .map_err(|error| {
                McpError::invalid_params(error.message.to_string(), Some((*error.details).clone()))
            })?;
        let workspace_root = if call.contains_relative_script_path() {
            workspace_root(&context).await
        } else {
            None
        };
        match call.resolve_scripts(workspace_root.as_deref()) {
            Ok(()) => {}
            Err(error) => return Ok(structured_error(error.mcp_envelope())),
        }
        Ok(self.execute(call).await)
    }
}

pub async fn run() -> AppResult<()> {
    let service = CodexLoopsServer::new()?
        .serve(stdio())
        .await
        .map_err(|error| AppError::new(6, "mcp_transport_failed", error.to_string()))?;
    service
        .waiting()
        .await
        .map_err(|error| AppError::new(6, "mcp_transport_failed", error.to_string()))?;
    Ok(())
}

#[allow(deprecated)]
async fn workspace_root(context: &RequestContext<RoleServer>) -> Option<PathBuf> {
    if let Ok(root) = std::env::var("CODEX_LOOPS_WORKSPACE_ROOT")
        && !root.is_empty()
    {
        return Some(PathBuf::from(root));
    }
    let client = context.peer.peer_info()?;
    client.capabilities.roots.as_ref()?;
    let roots = tokio::time::timeout(Duration::from_secs(1), context.peer.list_roots())
        .await
        .ok()?
        .ok()?;
    roots.roots.into_iter().find_map(|root| {
        url::Url::parse(&root.uri)
            .ok()
            .and_then(|uri| uri.to_file_path().ok())
    })
}

fn invalid_args(tool: &str, message: impl Into<String>) -> AppError {
    AppError::new(2, "invalid_params", message).details(json!({"tool": tool}))
}

fn tools() -> Vec<Tool> {
    vec![
        tool(
            "workflow_validate",
            "Validate a Codex Loops workflow script.",
            schema(&[("script_path", "string", true)]),
        ),
        tool(
            "workflow_start",
            "Start a Codex Loops workflow run.",
            schema(&[
                ("script_path", "string", true),
                ("run_id", "string", false),
                ("provider", "string", false),
                ("budget", "integer", false),
            ]),
        ),
        tool(
            "workflow_status",
            "Read the public §7.5 status projection through GET /api/runs/:id.",
            schema(&[("run_id", "string", true)]),
        ),
        tool(
            "workflow_inspect",
            "Read the public §7.5 inspect/status projection with ordered rawRefs through GET /api/runs/:id/events.",
            schema(&[("run_id", "string", true)]),
        ),
        tool(
            "workflow_resume",
            "Resume an existing scheduler run.",
            schema(&[
                ("run_id", "string", true),
                ("script_path", "string", false),
                ("script", "string", false),
                ("provider", "string", false),
            ]),
        ),
        tool(
            "workflow_open_ui",
            "Return the Phoenix LiveView URL for a scheduler run.",
            schema(&[("run_id", "string", true)]),
        ),
    ]
}

fn tool(name: &'static str, description: &'static str, input_schema: JsonObject) -> Tool {
    Tool::new(name, description, Arc::new(input_schema))
}

fn schema(fields: &[(&str, &str, bool)]) -> JsonObject {
    let mut properties = Map::new();
    let mut required = Vec::new();
    for (name, kind, is_required) in fields {
        let mut property = json!({"type": kind});
        if *kind == "string" {
            property["minLength"] = json!(1);
        }
        if *name == "provider" {
            property["enum"] = json!(["mock", "codex"]);
        }
        if *name == "budget" {
            property["minimum"] = json!(0);
        }
        properties.insert((*name).into(), property);
        if *is_required {
            required.push(*name);
        }
    }
    object(
        json!({"type": "object", "properties": properties, "required": required, "additionalProperties": false}),
    )
}

fn conform_projection(mut envelope: Value) -> Value {
    const FIELDS: &[&str] = &[
        "runId",
        "state",
        "treeName",
        "phase",
        "logs",
        "agentCount",
        "eventCount",
        "usage",
        "result",
        "failure",
        "agents",
        "rejected",
        "verifications",
        "judgments",
        "refines",
        "toolActivity",
        "journalEvents",
        "rawRefs",
    ];
    if let Some(data) = envelope.get_mut("data").and_then(Value::as_object_mut) {
        data.retain(|key, _| FIELDS.contains(&key.as_str()));
    }
    envelope
}

fn open_ui_envelope(envelope: Value, client: &SchedulerClient) -> Value {
    let mut data = envelope.get("data").cloned().unwrap_or_else(|| json!({}));
    if let Some(data) = data.as_object_mut() {
        let path = data
            .get("uiUrl")
            .or_else(|| data.get("uiPath"))
            .and_then(Value::as_str)
            .unwrap_or("/");
        let open_url = format!(
            "{}{}{}",
            client.base_url().as_str().trim_end_matches('/'),
            if path.starts_with('/') { "" } else { "/" },
            path
        );
        data.insert("open_url".into(), Value::String(open_url));
    }
    json!({"api_version": "codex-loops.mcp.v1", "data": data})
}

fn structured_error(value: Value) -> CallToolResult {
    CallToolResult::structured_error(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tool_catalog_is_complete_and_has_strict_schemas() {
        let tools = tools();
        let names: Vec<_> = tools.iter().map(|tool| tool.name.as_ref()).collect();
        assert_eq!(
            names,
            [
                "workflow_validate",
                "workflow_start",
                "workflow_status",
                "workflow_inspect",
                "workflow_resume",
                "workflow_open_ui"
            ]
        );
        assert!(
            tools
                .iter()
                .all(|tool| tool.input_schema.get("additionalProperties")
                    == Some(&Value::Bool(false)))
        );
    }

    #[test]
    fn invalid_arguments_are_rejected_before_execution() {
        let error = ToolCall::parse("workflow_start", JsonObject::new()).unwrap_err();
        assert_eq!(error.code.as_ref(), "invalid_params");
        let error = ToolCall::parse(
            "workflow_start",
            object(json!({"script_path": "/missing", "unexpected": true})),
        )
        .unwrap_err();
        assert_eq!(error.code.as_ref(), "invalid_params");
    }

    #[test]
    fn public_projection_hides_scheduler_only_fields() {
        let envelope = conform_projection(json!({
            "api_version": "scheduler.v1",
            "data": {"runId": "run-1", "state": "running", "lifecycleAction": {"action": "none"}}
        }));
        assert_eq!(
            envelope.pointer("/data/runId").and_then(Value::as_str),
            Some("run-1")
        );
        assert!(envelope.pointer("/data/lifecycleAction").is_none());
    }

    #[test]
    fn remote_resume_requires_shared_paths_only_when_a_script_is_supplied() {
        let client = SchedulerClient::new("https://scheduler.example.test").unwrap();
        assert!(
            !ToolCall::parse(
                "workflow_resume",
                object(json!({"run_id": "run-1", "provider": "mock"}))
            )
            .unwrap()
            .requires_shared_filesystem()
        );
        let call = ToolCall::parse(
            "workflow_resume",
            object(json!({"run_id": "run-1", "script_path": "/shared/workflow.exs"})),
        )
        .unwrap();
        let error = if call.requires_shared_filesystem() {
            require_shared_filesystem(&client).unwrap_err()
        } else {
            panic!("resume with a script must require a shared filesystem")
        };
        assert_eq!(
            error.code.as_ref(),
            "remote_scheduler_requires_shared_filesystem"
        );
    }
}
