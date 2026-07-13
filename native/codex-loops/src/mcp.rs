use std::{
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};

use rmcp::{
    ErrorData as ProtocolError, RoleServer, ServerHandler, ServiceExt,
    model::{
        CallToolRequestParams, CallToolResult, JsonObject, ListToolsResult, PaginatedRequestParams,
        ServerCapabilities, ServerInfo, Tool,
    },
    service::RequestContext,
    transport::stdio,
};
use schemars::{JsonSchema, Schema, generate::SchemaSettings, transform::RecursiveTransform};
use serde::{Deserialize, Deserializer};
use serde_json::{Value, json};

use crate::{
    cli::{ResolvedWorkflowScript, require_shared_filesystem},
    error::{AppError, AppResult, ExitStatus},
    scheduler::{
        Provider, ResumeRequest, RunId, SchedulerClient, SchedulerDocument, SchedulerResponse,
        StartRequest, WorkflowLocationRequest,
    },
};

#[derive(Clone)]
struct CodexLoopsServer {
    client: SchedulerClient,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
struct ValidateArgs {
    #[schemars(length(min = 1))]
    script_path: PathBuf,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
struct StartArgs {
    #[schemars(length(min = 1))]
    script_path: PathBuf,
    #[serde(default, deserialize_with = "deserialize_optional_field")]
    #[schemars(with = "RunId")]
    run_id: Option<RunId>,
    #[serde(default, deserialize_with = "deserialize_optional_field")]
    #[schemars(with = "Provider")]
    provider: Option<Provider>,
    #[serde(default, deserialize_with = "deserialize_optional_field")]
    #[schemars(with = "u64")]
    budget: Option<u64>,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
struct RunArgs {
    run_id: RunId,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
struct ResumeArgs {
    run_id: RunId,
    #[serde(
        default,
        alias = "script",
        deserialize_with = "deserialize_optional_field"
    )]
    #[schemars(with = "PathBuf", length(min = 1))]
    script_path: Option<PathBuf>,
    #[serde(default, deserialize_with = "deserialize_optional_field")]
    #[schemars(with = "Provider")]
    provider: Option<Provider>,
}

fn deserialize_optional_field<'de, D, T>(deserializer: D) -> Result<Option<T>, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de>,
{
    T::deserialize(deserializer).map(Some)
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

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum WorkspaceRootRequirement {
    NotNeeded,
    Optional,
    Required,
}

#[derive(Debug)]
enum ResolvedToolCall {
    Validate(ResolvedWorkflowScript),
    Start {
        script: ResolvedWorkflowScript,
        run_id: Option<RunId>,
        provider: Option<Provider>,
        budget: Option<u64>,
    },
    Status(RunId),
    Inspect(RunId),
    Resume {
        run_id: RunId,
        script: Option<ResolvedWorkflowScript>,
        provider: Option<Provider>,
    },
    OpenUi(RunId),
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
                    ExitStatus::Usage,
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

    fn workspace_root_requirement(&self) -> WorkspaceRootRequirement {
        match self {
            Self::Validate(args) if args.script_path.is_absolute() => {
                WorkspaceRootRequirement::Optional
            }
            Self::Validate(_args) => WorkspaceRootRequirement::Required,
            Self::Start(args) if args.script_path.is_absolute() => {
                WorkspaceRootRequirement::Optional
            }
            Self::Start(_args) => WorkspaceRootRequirement::Required,
            Self::Resume(args) => match &args.script_path {
                Some(path) if path.is_absolute() => WorkspaceRootRequirement::Optional,
                Some(_path) => WorkspaceRootRequirement::Required,
                None => WorkspaceRootRequirement::NotNeeded,
            },
            Self::Status(_args) | Self::Inspect(_args) | Self::OpenUi(_args) => {
                WorkspaceRootRequirement::NotNeeded
            }
        }
    }

    fn script_path(&self) -> Option<&Path> {
        match self {
            Self::Validate(args) => Some(&args.script_path),
            Self::Start(args) => Some(&args.script_path),
            Self::Resume(args) => args.script_path.as_deref(),
            Self::Status(_args) | Self::Inspect(_args) | Self::OpenUi(_args) => None,
        }
    }

    fn requires_shared_filesystem(&self) -> bool {
        match self {
            Self::Validate(_) | Self::Start(_) => true,
            Self::Resume(args) => args.script_path.is_some(),
            Self::Status(_) | Self::Inspect(_) | Self::OpenUi(_) => false,
        }
    }

    async fn resolve(self, workspace_root: Option<&Path>) -> AppResult<ResolvedToolCall> {
        match self {
            Self::Validate(ValidateArgs { script_path }) => Ok(ResolvedToolCall::Validate(
                ResolvedWorkflowScript::resolve_from(&script_path, workspace_root).await?,
            )),
            Self::Start(StartArgs {
                script_path,
                run_id,
                provider,
                budget,
            }) => Ok(ResolvedToolCall::Start {
                script: ResolvedWorkflowScript::resolve_from(&script_path, workspace_root).await?,
                run_id,
                provider,
                budget,
            }),
            Self::Status(RunArgs { run_id }) => Ok(ResolvedToolCall::Status(run_id)),
            Self::Inspect(RunArgs { run_id }) => Ok(ResolvedToolCall::Inspect(run_id)),
            Self::Resume(ResumeArgs {
                run_id,
                script_path,
                provider,
            }) => {
                let script = match script_path {
                    Some(path) => {
                        Some(ResolvedWorkflowScript::resolve_from(&path, workspace_root).await?)
                    }
                    None => None,
                };
                Ok(ResolvedToolCall::Resume {
                    run_id,
                    script,
                    provider,
                })
            }
            Self::OpenUi(RunArgs { run_id }) => Ok(ResolvedToolCall::OpenUi(run_id)),
        }
    }
}

impl CodexLoopsServer {
    fn new() -> AppResult<Self> {
        Ok(Self {
            client: SchedulerClient::from_env()?,
        })
    }

    async fn execute(&self, call: ResolvedToolCall) -> CallToolResult {
        if let Err(error) = self.client.require_compatible().await {
            return CallToolResult::structured_error(error.mcp_envelope());
        }

        let result: AppResult<Value> = match call {
            ResolvedToolCall::Validate(script) => self
                .client
                .validate(script.as_str())
                .await
                .and_then(SchedulerResponse::into_wire_value),
            ResolvedToolCall::Start {
                script,
                run_id,
                provider,
                budget,
            } => {
                let location = script.into_location();
                self.client
                    .start(&StartRequest {
                        script_path: location.script_path,
                        workspace_root: location.workspace_root,
                        run_id,
                        provider,
                        budget,
                    })
                    .await
                    .and_then(SchedulerResponse::into_wire_value)
            }
            ResolvedToolCall::Status(run_id) => {
                self.client.status(&run_id).await.map(conform_projection)
            }
            ResolvedToolCall::Inspect(run_id) => {
                self.client.inspect(&run_id).await.map(conform_projection)
            }
            ResolvedToolCall::Resume {
                run_id,
                script,
                provider,
            } => {
                let request = match script {
                    Some(script) => {
                        let location = script.into_location();
                        ResumeRequest {
                            workflow: Some(WorkflowLocationRequest {
                                script_path: location.script_path,
                                workspace_root: location.workspace_root,
                            }),
                            provider,
                        }
                    }
                    None => ResumeRequest {
                        workflow: None,
                        provider,
                    },
                };
                self.client
                    .resume(&run_id, &request)
                    .await
                    .and_then(SchedulerResponse::into_wire_value)
            }
            ResolvedToolCall::OpenUi(run_id) => self
                .client
                .status(&run_id)
                .await
                .and_then(|response| open_ui_envelope(response, &self.client)),
        };
        match result {
            Ok(value) => CallToolResult::structured(value),
            Err(error) => CallToolResult::structured_error(error.mcp_envelope()),
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
    ) -> Result<ListToolsResult, ProtocolError> {
        tools()
            .map(ListToolsResult::with_all_items)
            .map_err(|error| {
                let report = error.into_report();
                ProtocolError::internal_error(report.message, Some(report.details))
            })
    }

    async fn call_tool(
        &self,
        request: CallToolRequestParams,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ProtocolError> {
        let call = ToolCall::parse(&request.name, request.arguments.unwrap_or_default()).map_err(
            |error| {
                let report = error.into_report();
                ProtocolError::invalid_params(report.message, Some(report.details))
            },
        )?;
        let requires_shared_filesystem = call.requires_shared_filesystem();
        let workspace_root = match workspace_root(
            &context,
            call.workspace_root_requirement(),
            call.script_path(),
        )
        .await
        {
            Ok(root) => root,
            Err(error) => return Ok(CallToolResult::structured_error(error.mcp_envelope())),
        };
        let call = match call.resolve(workspace_root.as_deref()).await {
            Ok(call) => call,
            Err(error) => return Ok(CallToolResult::structured_error(error.mcp_envelope())),
        };
        if requires_shared_filesystem && let Err(error) = require_shared_filesystem(&self.client) {
            return Ok(CallToolResult::structured_error(error.mcp_envelope()));
        }
        Ok(self.execute(call).await)
    }
}

pub async fn run() -> AppResult<()> {
    let service = CodexLoopsServer::new()?
        .serve(stdio())
        .await
        .map_err(mcp_transport_error)?;
    service.waiting().await.map_err(mcp_transport_error)?;
    Ok(())
}

fn mcp_transport_error(error: impl std::fmt::Display) -> AppError {
    AppError::new(
        ExitStatus::Runtime,
        "mcp_transport_failed",
        error.to_string(),
    )
}

#[allow(deprecated)]
async fn workspace_root(
    context: &RequestContext<RoleServer>,
    requirement: WorkspaceRootRequirement,
    script_path: Option<&Path>,
) -> AppResult<Option<PathBuf>> {
    if requirement == WorkspaceRootRequirement::NotNeeded {
        return Ok(None);
    }
    match std::env::var("CODEX_LOOPS_WORKSPACE_ROOT") {
        Ok(root) if !root.is_empty() => {
            let root = PathBuf::from(root);
            if root.is_absolute() {
                return Ok(Some(root));
            }
            return Err(workspace_root_config_error(
                "CODEX_LOOPS_WORKSPACE_ROOT must be an absolute path.",
                json!({"workspace_root": root}),
            ));
        }
        Ok(_) | Err(std::env::VarError::NotPresent) => {}
        Err(std::env::VarError::NotUnicode(root)) => {
            return Err(workspace_root_config_error(
                "CODEX_LOOPS_WORKSPACE_ROOT must contain valid Unicode.",
                json!({"value": root.to_string_lossy()}),
            ));
        }
    }

    let client = match context.peer.peer_info() {
        Some(client) => client,
        None => {
            return missing_workspace_root(
                requirement,
                workspace_root_error(
                    "The MCP client did not provide initialization information for resolving the relative workflow path.",
                    json!({"source": "client_initialize"}),
                ),
            );
        }
    };
    if client.capabilities.roots.is_none() {
        return missing_workspace_root(
            requirement,
            workspace_root_error(
                "The MCP client does not support workspace roots; set CODEX_LOOPS_WORKSPACE_ROOT to resolve relative workflow paths.",
                json!({"missing_capability": "roots"}),
            ),
        );
    }
    let roots = match tokio::time::timeout(Duration::from_secs(1), context.peer.list_roots()).await
    {
        Ok(Ok(roots)) => roots,
        Ok(Err(error)) => {
            return missing_workspace_root(
                requirement,
                workspace_root_error(
                    "The MCP client rejected the workspace-roots request.",
                    json!({"reason": error.to_string()}),
                ),
            );
        }
        Err(_elapsed) => {
            return missing_workspace_root(
                requirement,
                workspace_root_error(
                    "Timed out while requesting workspace roots from the MCP client.",
                    json!({"timeout_ms": 1_000}),
                ),
            );
        }
    };
    let local_roots: Vec<PathBuf> = roots
        .roots
        .iter()
        .filter_map(|root| {
            url::Url::parse(&root.uri)
                .ok()
                .and_then(|uri| uri.to_file_path().ok())
        })
        .collect();
    match select_workspace_root(local_roots, script_path).await {
        Some(root) => Ok(Some(root)),
        None => missing_workspace_root(
            requirement,
            workspace_root_error(
                "The MCP client did not return a local filesystem workspace root; set CODEX_LOOPS_WORKSPACE_ROOT to resolve relative workflow paths.",
                json!({"roots": roots.roots.iter().map(|root| &root.uri).collect::<Vec<_>>() }),
            ),
        ),
    }
}

async fn select_workspace_root(roots: Vec<PathBuf>, script_path: Option<&Path>) -> Option<PathBuf> {
    let Some(script_path) = script_path.filter(|path| path.is_absolute()) else {
        return roots.into_iter().next();
    };
    let canonical_script = tokio::fs::canonicalize(script_path).await.ok();
    let mut selected = None;
    for root in roots {
        let canonical_root = tokio::fs::canonicalize(&root).await.ok();
        let candidate = canonical_root.as_deref().unwrap_or(&root);
        let contains_script = canonical_script
            .as_deref()
            .is_some_and(|script| script.starts_with(candidate))
            || script_path.starts_with(&root);
        if contains_script
            && selected.as_ref().is_none_or(|current: &PathBuf| {
                candidate.components().count() > current.components().count()
            })
        {
            selected = Some(candidate.to_path_buf());
        }
    }
    selected
}

fn missing_workspace_root(
    requirement: WorkspaceRootRequirement,
    error: AppError,
) -> AppResult<Option<PathBuf>> {
    match requirement {
        WorkspaceRootRequirement::NotNeeded | WorkspaceRootRequirement::Optional => Ok(None),
        WorkspaceRootRequirement::Required => Err(error),
    }
}

fn workspace_root_error(message: &str, details: Value) -> AppError {
    AppError::new(
        ExitStatus::Prerequisite,
        "workspace_root_unavailable",
        message,
    )
    .details(details)
}

fn workspace_root_config_error(message: &str, details: Value) -> AppError {
    AppError::new(ExitStatus::Usage, "workspace_root_invalid", message).details(details)
}

fn invalid_args(tool: &str, message: impl Into<String>) -> AppError {
    AppError::new(ExitStatus::Usage, "invalid_params", message).details(json!({"tool": tool}))
}

fn tools() -> AppResult<Vec<Tool>> {
    Ok(vec![
        typed_tool::<ValidateArgs>(
            "workflow_validate",
            "Validate a Codex Loops workflow script.",
        )?,
        typed_tool::<StartArgs>("workflow_start", "Start a Codex Loops workflow run.")?,
        typed_tool::<RunArgs>(
            "workflow_status",
            "Read the public §7.5 status projection through GET /api/runs/:id.",
        )?,
        typed_tool::<RunArgs>(
            "workflow_inspect",
            "Read the public §7.5 inspect/status projection with ordered rawRefs through GET /api/runs/:id/events.",
        )?,
        tool(
            "workflow_resume",
            "Resume an existing scheduler run.",
            resume_schema()?,
        ),
        typed_tool::<RunArgs>(
            "workflow_open_ui",
            "Return the Phoenix LiveView URL for a scheduler run.",
        )?,
    ])
}

fn typed_tool<T: JsonSchema>(name: &'static str, description: &'static str) -> AppResult<Tool> {
    Ok(tool(name, description, input_schema::<T>()?))
}

fn tool(name: &'static str, description: &'static str, input_schema: JsonObject) -> Tool {
    Tool::new(name, description, Arc::new(input_schema))
}

fn input_schema<T: JsonSchema>() -> AppResult<JsonObject> {
    let schema = SchemaSettings::default()
        .with(|settings| {
            settings.meta_schema = None;
            settings.inline_subschemas = true;
        })
        .with_transform(RecursiveTransform(|schema: &mut Schema| {
            schema.remove("default");
        }))
        .into_generator()
        .into_root_schema_for::<T>()
        .to_value();
    if let Value::Object(schema) = schema {
        Ok(schema)
    } else {
        Err(schema_error(
            "An MCP argument DTO generated a non-object JSON schema.",
            schema,
        ))
    }
}

fn resume_schema() -> AppResult<JsonObject> {
    let mut schema = input_schema::<ResumeArgs>()?;
    let Some(script_path_schema) = schema
        .get("properties")
        .and_then(Value::as_object)
        .and_then(|properties| properties.get("script_path"))
        .cloned()
    else {
        return Err(schema_error(
            "The workflow_resume schema omitted script_path.",
            Value::Object(schema),
        ));
    };
    let Some(properties) = schema.get_mut("properties").and_then(Value::as_object_mut) else {
        return Err(schema_error(
            "The workflow_resume schema omitted its properties object.",
            Value::Object(schema),
        ));
    };
    // The legacy wire alias intentionally has the same schema as its canonical field.
    properties.insert("script".into(), script_path_schema);
    Ok(schema)
}

fn schema_error(message: &str, schema: Value) -> AppError {
    AppError::new(ExitStatus::Runtime, "mcp_schema_invalid", message)
        .details(json!({"schema": schema}))
}

fn conform_projection(response: SchedulerResponse<SchedulerDocument>) -> Value {
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
    let SchedulerResponse {
        api_version,
        data: SchedulerDocument { mut fields },
    } = response;
    fields.retain(|key, _| FIELDS.contains(&key.as_str()));
    json!({"api_version": api_version, "data": fields})
}

fn open_ui_envelope(
    response: SchedulerResponse<SchedulerDocument>,
    client: &SchedulerClient,
) -> AppResult<Value> {
    let SchedulerResponse {
        data: SchedulerDocument { mut fields },
        ..
    } = response;
    let path = fields
        .get("uiUrl")
        .or_else(|| fields.get("uiPath"))
        .and_then(Value::as_str)
        .filter(|path| !path.is_empty())
        .ok_or_else(|| {
            AppError::scheduler(
                ExitStatus::Runtime,
                "scheduler_response",
                "Scheduler status data did not contain a non-empty uiUrl or uiPath.",
            )
            .details(json!({"data": &fields}))
        })?;
    let open_url = client.base_url().join(path).map_err(|error| {
        AppError::scheduler(
            ExitStatus::Runtime,
            "scheduler_response",
            "Scheduler status data contained an invalid UI path.",
        )
        .details(json!({"ui_path": path, "reason": error.to_string()}))
    })?;
    fields.insert("open_url".into(), Value::String(open_url.to_string()));
    Ok(json!({"api_version": "codex-loops.mcp.v1", "data": fields}))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn arguments(value: Value) -> JsonObject {
        rmcp::model::object(value)
    }

    fn scheduler_response(data: Value) -> SchedulerResponse<SchedulerDocument> {
        serde_json::from_value(json!({"api_version": "scheduler.v1", "data": data})).unwrap()
    }

    fn schema_property<'a>(tool: &'a Tool, name: &str) -> Option<&'a Value> {
        tool.input_schema
            .get("properties")
            .and_then(Value::as_object)
            .and_then(|properties| properties.get(name))
    }

    #[test]
    fn tool_catalog_is_complete_and_has_strict_schemas() {
        let tools = tools().unwrap();
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

        let start = tools
            .iter()
            .find(|tool| tool.name == "workflow_start")
            .unwrap();
        assert_eq!(
            schema_property(start, "provider").and_then(|schema| schema.get("enum")),
            Some(&json!(["mock", "codex"]))
        );
        assert_eq!(
            schema_property(start, "budget").and_then(|schema| schema.get("minimum")),
            Some(&json!(0))
        );
        assert!(
            schema_property(start, "budget")
                .and_then(|schema| schema.get("default"))
                .is_none()
        );
        let resume = tools
            .iter()
            .find(|tool| tool.name == "workflow_resume")
            .unwrap();
        assert_eq!(
            schema_property(resume, "script"),
            schema_property(resume, "script_path")
        );
        assert_eq!(
            schema_property(resume, "script_path").and_then(|schema| schema.get("minLength")),
            Some(&json!(1))
        );
    }

    #[test]
    fn invalid_arguments_are_rejected_before_execution() {
        let error = ToolCall::parse("workflow_start", JsonObject::new()).unwrap_err();
        assert_eq!(error.code(), "invalid_params");
        let error = ToolCall::parse(
            "workflow_start",
            arguments(json!({"script_path": "/missing", "unexpected": true})),
        )
        .unwrap_err();
        assert_eq!(error.code(), "invalid_params");
        let error = ToolCall::parse(
            "workflow_start",
            arguments(json!({"script_path": "/missing", "provider": null})),
        )
        .unwrap_err();
        assert_eq!(error.code(), "invalid_params");
        let error = ToolCall::parse(
            "workflow_resume",
            arguments(json!({"run_id": "run-1", "script": null})),
        )
        .unwrap_err();
        assert_eq!(error.code(), "invalid_params");
    }

    #[test]
    fn workspace_roots_are_required_only_for_relative_script_paths() {
        let relative = ToolCall::parse(
            "workflow_start",
            arguments(json!({"script_path": ".codex/workflows/review.exs"})),
        )
        .unwrap();
        let absolute = ToolCall::parse(
            "workflow_start",
            arguments(json!({"script_path": "/tmp/review.exs"})),
        )
        .unwrap();
        let pathless =
            ToolCall::parse("workflow_resume", arguments(json!({"run_id": "run-1"}))).unwrap();

        assert_eq!(
            relative.workspace_root_requirement(),
            WorkspaceRootRequirement::Required
        );
        assert_eq!(
            absolute.workspace_root_requirement(),
            WorkspaceRootRequirement::Optional
        );
        assert_eq!(
            pathless.workspace_root_requirement(),
            WorkspaceRootRequirement::NotNeeded
        );
    }

    #[tokio::test]
    async fn absolute_scripts_choose_the_deepest_containing_client_root() {
        let root = tempfile::tempdir().unwrap();
        let unrelated = root.path().join("unrelated");
        let workspace = root.path().join("workspace");
        let nested = workspace.join("nested");
        tokio::fs::create_dir_all(&unrelated).await.unwrap();
        tokio::fs::create_dir_all(&nested).await.unwrap();
        let script = nested.join("review.exs");
        tokio::fs::write(&script, "workflow \"test\" do\nend\n")
            .await
            .unwrap();

        let selected =
            select_workspace_root(vec![unrelated, workspace, nested.clone()], Some(&script))
                .await
                .unwrap();

        assert_eq!(selected, tokio::fs::canonicalize(nested).await.unwrap());
    }

    #[test]
    fn resume_script_alias_normalizes_to_one_typed_field() {
        let call = ToolCall::parse(
            "workflow_resume",
            serde_json::from_value(json!({"run_id": "run-1", "script": "/tmp/a.exs"})).unwrap(),
        )
        .unwrap();
        assert!(matches!(
            call,
            ToolCall::Resume(ResumeArgs {
                script_path: Some(_),
                ..
            })
        ));

        let duplicate: JsonObject = serde_json::from_value(json!({
            "run_id": "run-1",
            "script": "/tmp/a.exs",
            "script_path": "/tmp/b.exs"
        }))
        .unwrap();
        assert!(ToolCall::parse("workflow_resume", duplicate).is_err());
    }

    #[test]
    fn public_projection_hides_scheduler_only_fields() {
        let envelope = conform_projection(scheduler_response(json!({
            "runId": "run-1",
            "state": "running",
            "lifecycleAction": {"action": "none"}
        })));
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
                arguments(json!({"run_id": "run-1", "provider": "mock"}))
            )
            .unwrap()
            .requires_shared_filesystem()
        );
        let call = ToolCall::parse(
            "workflow_resume",
            arguments(json!({"run_id": "run-1", "script_path": "/shared/workflow.exs"})),
        )
        .unwrap();
        let error = if call.requires_shared_filesystem() {
            require_shared_filesystem(&client).unwrap_err()
        } else {
            panic!("resume with a script must require a shared filesystem")
        };
        assert_eq!(error.code(), "remote_scheduler_requires_shared_filesystem");
    }

    #[test]
    fn open_ui_requires_a_scheduler_ui_path() {
        let client = SchedulerClient::new("http://127.0.0.1:47125").unwrap();
        let error = open_ui_envelope(
            scheduler_response(json!({"runId": "run-1", "state": "running"})),
            &client,
        )
        .unwrap_err();

        assert_eq!(error.code(), "scheduler_response");
        assert_eq!(error.mcp_envelope()["api_version"], "scheduler.v1");
    }

    #[test]
    fn open_ui_joins_the_typed_scheduler_path() {
        let client = SchedulerClient::new("http://127.0.0.1:47125").unwrap();
        let envelope = open_ui_envelope(
            scheduler_response(json!({"runId": "run-1", "uiUrl": "/runs/run-1"})),
            &client,
        )
        .unwrap();

        assert_eq!(
            envelope["data"]["open_url"],
            "http://127.0.0.1:47125/runs/run-1"
        );
    }
}
