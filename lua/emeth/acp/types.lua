---@meta
--- ACP (Agent Client Protocol) type definitions

---@class acp.ClientCapabilities
---@field fs acp.FileSystemCapability

---@class acp.FileSystemCapability
---@field readTextFile boolean
---@field writeTextFile boolean

---@class acp.AgentCapabilities
---@field loadSession boolean
---@field sessionCapabilities? { list?: table }
---@field promptCapabilities acp.PromptCapabilities

---@class acp.PromptCapabilities
---@field image boolean
---@field audio boolean
---@field embeddedContext boolean

---@class acp.AuthMethod
---@field id string
---@field name string
---@field description string|nil

---@class acp.McpServer
---@field name string
---@field command string
---@field args string[]
---@field env acp.EnvVariable[]

---@class acp.EnvVariable
---@field name string
---@field value string

---@alias acp.StopReason "end_turn" | "max_tokens" | "max_turn_requests" | "refusal" | "cancelled"
---@alias acp.ToolKind "read" | "edit" | "delete" | "move" | "search" | "execute" | "think" | "fetch" | "other"
---@alias acp.ToolCallStatus "pending" | "in_progress" | "completed" | "failed"
---@alias acp.PlanEntryStatus "pending" | "in_progress" | "completed"
---@alias acp.PlanEntryPriority "high" | "medium" | "low"

---@class acp.BaseContent
---@field type "text" | "image" | "audio" | "resource_link" | "resource"
---@field annotations acp.Annotations|nil

---@class acp.TextContent : acp.BaseContent
---@field type "text"
---@field text string

---@class acp.ImageContent : acp.BaseContent
---@field type "image"
---@field data string
---@field mimeType string
---@field uri string|nil

---@class acp.AudioContent : acp.BaseContent
---@field type "audio"
---@field data string
---@field mimeType string

---@class acp.ResourceLinkContent : acp.BaseContent
---@field type "resource_link"
---@field uri string
---@field name string
---@field description string|nil
---@field mimeType string|nil
---@field size number|nil
---@field title string|nil

---@class acp.ResourceContent : acp.BaseContent
---@field type "resource"
---@field resource acp.EmbeddedResource

---@class acp.EmbeddedResource
---@field uri string
---@field text string|nil
---@field blob string|nil
---@field mimeType string|nil

---@class acp.Annotations
---@field audience any[]|nil
---@field lastModified string|nil
---@field priority number|nil

---@alias acp.Content acp.TextContent | acp.ImageContent | acp.AudioContent | acp.ResourceLinkContent | acp.ResourceContent

---@class acp.ToolCall
---@field toolCallId string
---@field title string
---@field kind acp.ToolKind
---@field status acp.ToolCallStatus
---@field content acp.ToolCallContent[]
---@field locations acp.ToolCallLocation[]
---@field rawInput table
---@field rawOutput table

---@class acp.BaseToolCallContent
---@field type "content" | "diff"

---@class acp.ToolCallRegularContent : acp.BaseToolCallContent
---@field type "content"
---@field content acp.Content

---@class acp.ToolCallDiffContent : acp.BaseToolCallContent
---@field type "diff"
---@field path string
---@field oldText string|nil
---@field newText string

---@alias acp.ToolCallContent acp.ToolCallRegularContent | acp.ToolCallDiffContent

---@class acp.ToolCallLocation
---@field path string
---@field line number|nil

---@class acp.PlanEntry
---@field content string
---@field priority acp.PlanEntryPriority
---@field status acp.PlanEntryStatus

---@class acp.Plan
---@field entries acp.PlanEntry[]

---@class acp.AvailableCommand
---@field name string
---@field description string
---@field input? table<string, any>

---@class acp.BaseSessionUpdate
---@field sessionUpdate "user_message_chunk" | "agent_message_chunk" | "agent_thought_chunk" | "tool_call" | "tool_call_update" | "plan" | "available_commands_update" | "session_info_update"

---@class acp.UserMessageChunk : acp.BaseSessionUpdate
---@field sessionUpdate "user_message_chunk"
---@field content acp.Content

---@class acp.AgentMessageChunk : acp.BaseSessionUpdate
---@field sessionUpdate "agent_message_chunk"
---@field content acp.Content

---@class acp.AgentThoughtChunk : acp.BaseSessionUpdate
---@field sessionUpdate "agent_thought_chunk"
---@field content acp.Content

---@class acp.ToolCallUpdate : acp.BaseSessionUpdate
---@field sessionUpdate "tool_call" | "tool_call_update"
---@field toolCallId string
---@field title string|nil
---@field kind acp.ToolKind|nil
---@field status acp.ToolCallStatus|nil
---@field content acp.ToolCallContent[]|nil
---@field locations acp.ToolCallLocation[]|nil
---@field rawInput table|nil
---@field rawOutput table|nil

---@class acp.PlanUpdate : acp.BaseSessionUpdate
---@field sessionUpdate "plan"
---@field entries acp.PlanEntry[]

---@class acp.AvailableCommandsUpdate : acp.BaseSessionUpdate
---@field sessionUpdate "available_commands_update"
---@field availableCommands acp.AvailableCommand[]

---@class acp.SessionInfoUpdate : acp.BaseSessionUpdate
---@field sessionUpdate "session_info_update"
---@field title? string|nil
---@field updatedAt? string|nil
---@field _meta? table

---@class acp.SessionInfo
---@field sessionId string
---@field cwd string
---@field title? string
---@field updatedAt? string
---@field _meta? table

---@class acp.PermissionOption
---@field optionId string
---@field name string
---@field kind "allow_once" | "allow_always" | "reject_once" | "reject_always"

---@class acp.RequestPermissionOutcome
---@field outcome "cancelled" | "selected"
---@field optionId string|nil

---@class acp.ACPTransport
---@field send function
---@field start function
---@field stop function

---@alias acp.ConnectionState "disconnected" | "connecting" | "connected" | "initializing" | "ready" | "error"

---@class acp.ACPError
---@field code number
---@field message string
---@field data any|nil

---@class acp.Handlers
---@field on_session_update? fun(update: acp.AgentMessageChunk | acp.AgentThoughtChunk | acp.ToolCallUpdate | acp.PlanUpdate | acp.AvailableCommandsUpdate, session_id: string)
---@field on_request_permission? fun(tool_call: table, options: table[], callback: fun(option_id: string|nil)): nil
---@field on_read_file? fun(path: string, line: integer|nil, limit: integer|nil, callback: fun(content: string), error_callback: fun(message: string, code: integer|nil)): nil
---@field on_write_file? fun(path: string, content: string, callback: fun(error: string|nil)): nil
---@field on_error? fun(error: table)
---@field on_notification? fun(method: string, params: table, message_id: number|nil)

---@class acp.ClientConfig
---@field transport_type? "stdio" | "websocket" | "tcp"
---@field command? string
---@field args? string[]
---@field env? table
---@field timeout? number
---@field reconnect? boolean
---@field max_reconnect_attempts? number
---@field auth_method? string
---@field handlers? acp.Handlers
---@field on_state_change? fun(new_state: acp.ConnectionState, old_state: acp.ConnectionState)

return {}
