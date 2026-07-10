use std::{
    collections::BTreeSet,
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
use serde_json::{Map, Value, json};

use crate::{
    cli::{require_shared_filesystem, resolve_script_from},
    error::{AppError, AppResult},
    lifecycle,
    scheduler::SchedulerClient,
};

#[derive(Clone)]
struct CodexLoopsServer {
    client: SchedulerClient,
}

impl CodexLoopsServer {
    fn new() -> AppResult<Self> {
        Ok(Self {
            client: SchedulerClient::from_env()?,
        })
    }

    async fn execute(&self, name: &str, args: Value) -> CallToolResult {
        if let Err(error) = require_shared_filesystem_for_tool(&self.client, name, &args) {
            return structured_error(error.mcp_envelope());
        }
        if let Err(error) = lifecycle::ensure_ready(&self.client).await {
            return structured_error(error.mcp_envelope());
        }

        let result = match name {
            "workflow_validate" => {
                self.client
                    .validate(args["script_path"].as_str().unwrap())
                    .await
            }
            "workflow_start" => self.client.start(args).await,
            "workflow_status" => self
                .client
                .status(args["run_id"].as_str().unwrap())
                .await
                .map(conform_projection),
            "workflow_inspect" => self
                .client
                .inspect(args["run_id"].as_str().unwrap())
                .await
                .map(conform_projection),
            "workflow_resume" => {
                let run_id = args["run_id"].as_str().unwrap().to_owned();
                self.client
                    .resume(&run_id, take(&args, &["script_path", "script", "provider"]))
                    .await
            }
            "workflow_open_ui" => {
                let run_id = args["run_id"].as_str().unwrap();
                self.client
                    .status(run_id)
                    .await
                    .map(|envelope| open_ui_envelope(envelope, &self.client))
            }
            _ => unreachable!("tool name was validated before execution"),
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
        let args = validate_argument_shape(&request.name, request.arguments.unwrap_or_default())
            .map_err(|error| {
                McpError::invalid_params(error.message.to_string(), Some(*error.details))
            })?;
        let workspace_root = if contains_relative_script_path(&args) {
            workspace_root(&context).await
        } else {
            None
        };
        let args = match resolve_script_arguments(&request.name, args, workspace_root.as_deref()) {
            Ok(args) => args,
            Err(error) => return Ok(structured_error(error.mcp_envelope())),
        };
        Ok(self.execute(&request.name, args).await)
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

fn validate_argument_shape(name: &str, arguments: JsonObject) -> AppResult<Value> {
    let (allowed, required): (&[&str], &[&str]) = match name {
        "workflow_validate" => (&["script_path"], &["script_path"]),
        "workflow_start" => (
            &["script_path", "run_id", "provider", "budget"],
            &["script_path"],
        ),
        "workflow_status" | "workflow_inspect" | "workflow_open_ui" => (&["run_id"], &["run_id"]),
        "workflow_resume" => (
            &["run_id", "script_path", "script", "provider"],
            &["run_id"],
        ),
        _ => {
            return Err(AppError::new(
                2,
                "unknown_tool",
                format!("Unknown tool: {name}"),
            ));
        }
    };

    let unknown: Vec<_> = arguments
        .keys()
        .filter(|key| !allowed.contains(&key.as_str()))
        .cloned()
        .collect();
    if !unknown.is_empty() {
        return Err(invalid_args(
            name,
            format!("Unknown arguments: {}", unknown.join(", ")),
        ));
    }
    for key in required {
        required_non_empty_string(&arguments, key)
            .map_err(|message| invalid_args(name, message))?;
    }
    for key in ["run_id", "script_path", "script"] {
        if let Some(value) = arguments.get(key)
            && value.as_str().is_none_or(str::is_empty)
        {
            return Err(invalid_args(
                name,
                format!("{key} must be a non-empty string"),
            ));
        }
    }
    if let Some(provider) = arguments.get("provider")
        && !matches!(provider.as_str(), Some("mock" | "codex"))
    {
        return Err(invalid_args(name, "provider must be mock or codex"));
    }
    if let Some(budget) = arguments.get("budget")
        && budget.as_u64().is_none()
    {
        return Err(invalid_args(name, "budget must be a non-negative integer"));
    }

    Ok(Value::Object(arguments))
}

fn resolve_script_arguments(
    _name: &str,
    mut normalized: Value,
    workspace_root: Option<&Path>,
) -> AppResult<Value> {
    for key in ["script_path", "script"] {
        if let Some(raw) = normalized.get(key).and_then(Value::as_str) {
            let path = resolve_script_from(Path::new(raw), workspace_root)?;
            normalized[key] = Value::String(path.to_string_lossy().into_owned());
        }
    }
    Ok(normalized)
}

fn contains_relative_script_path(arguments: &Value) -> bool {
    ["script_path", "script"].iter().any(|key| {
        arguments
            .get(key)
            .and_then(Value::as_str)
            .is_some_and(|path| !Path::new(path).is_absolute())
    })
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

fn required_non_empty_string(arguments: &JsonObject, key: &str) -> Result<(), String> {
    if arguments
        .get(key)
        .and_then(Value::as_str)
        .is_some_and(|value| !value.is_empty())
    {
        Ok(())
    } else {
        Err(format!("{key} must be a non-empty string"))
    }
}

fn invalid_args(tool: &str, message: impl Into<String>) -> AppError {
    AppError::new(2, "invalid_params", message).details(json!({"tool": tool}))
}

fn require_shared_filesystem_for_tool(
    client: &SchedulerClient,
    name: &str,
    arguments: &Value,
) -> AppResult<()> {
    if matches!(name, "workflow_validate" | "workflow_start")
        || (name == "workflow_resume"
            && ["script_path", "script"]
                .iter()
                .any(|key| arguments.get(key).is_some()))
    {
        require_shared_filesystem(client)
    } else {
        Ok(())
    }
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

fn take(value: &Value, keys: &[&str]) -> Value {
    let allowed: BTreeSet<_> = keys.iter().copied().collect();
    Value::Object(
        value
            .as_object()
            .into_iter()
            .flatten()
            .filter(|(key, _)| allowed.contains(key.as_str()))
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect(),
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
        let error = validate_argument_shape("workflow_start", JsonObject::new()).unwrap_err();
        assert_eq!(error.code.as_ref(), "invalid_params");
        let error = validate_argument_shape(
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
            require_shared_filesystem_for_tool(
                &client,
                "workflow_resume",
                &json!({"run_id": "run-1", "provider": "mock"})
            )
            .is_ok()
        );
        let error = require_shared_filesystem_for_tool(
            &client,
            "workflow_resume",
            &json!({"run_id": "run-1", "script_path": "/shared/workflow.exs"}),
        )
        .unwrap_err();
        assert_eq!(
            error.code.as_ref(),
            "remote_scheduler_requires_shared_filesystem"
        );
    }
}
