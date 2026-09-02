--- Elicitation schema logic — pure ACP spec, no UI and no provider knowledge.
---
--- The agent sends `elicitation/create` with a `requestedSchema` (a restricted
--- JSON Schema: an object whose properties are all primitives). This module
--- turns that schema into an ordered list of field descriptors the UI can walk,
--- and folds the user's answers back into the `content` object the agent wants.
---
--- Field kinds map onto the spec's property types:
---   select        string with `enum` / `oneOf`   pick exactly one
---   multi_select  array with `items.enum/anyOf`  pick zero or more
---   text          string                         free text
---   boolean       boolean                        yes / no
---   number        number | integer               numeric (integer rounds)
---
--- Anything else (a custom `_`-prefixed type, or a future ACP type) becomes
--- kind `unsupported`: the spec requires we not render it as a known control,
--- so the UI skips it and it is simply absent from the response content.

local M = {}

---@class acp.ElicitationOption
---@field value string        the wire value (`const`, or the bare enum entry)
---@field label string        human-readable label
---@field description? string
---@field meta? table         the option's `_meta`, for provider hooks
---@field preview? string     long-form body shown when expanded; set by a
---                          provider hook from its own `_meta` namespace

---@class acp.ElicitationField
---@field key string          property name; the key in the response `content`
---@field kind "select"|"multi_select"|"text"|"boolean"|"number"|"unsupported"
---@field title? string
---@field description? string
---@field required boolean
---@field options? acp.ElicitationOption[]  for select / multi_select
---@field default? any
---@field integer? boolean    number fields that must round to an integer
---@field meta? table         the property's `_meta`, for provider hooks
---@field custom_key? string  a sibling free-text field whose answer substitutes
---                          for this one's; set by a provider hook, which is
---                          also responsible for dropping the sibling field

---Normalize a JSON value that may arrive as `vim.NIL`.
---@param v any
---@return any|nil
local function nz(v)
  if v == nil or v == vim.NIL then
    return nil
  end
  return v
end

---A non-empty string, or nil. Guards both `vim.NIL` and the empty string.
---@param v any
---@return string|nil
local function str(v)
  v = nz(v)
  if type(v) == "string" and v ~= "" then
    return v
  end
  return nil
end

---Read the option list out of a property schema. The spec allows two spellings:
---a bare `enum` array of strings, or `oneOf`/`anyOf` carrying titled
---`EnumOption`s (`{ const, title, description? }`). Titled options win when both
---are present, since they carry strictly more information.
---@param schema table
---@param titled_key "oneOf"|"anyOf"
---@return acp.ElicitationOption[]|nil
local function read_options(schema, titled_key)
  local titled = nz(schema[titled_key])
  if type(titled) == "table" and #titled > 0 then
    local out = {}
    for _, opt in ipairs(titled) do
      -- `const` is required by the spec; skip malformed entries rather than
      -- rendering an option that can't be sent back.
      local value = str(type(opt) == "table" and opt.const)
      if value then
        out[#out + 1] = {
          value = value,
          label = str(opt.title) or value,
          description = str(opt.description),
          meta = nz(opt._meta),
        }
      end
    end
    if #out > 0 then
      return out
    end
  end

  local enum = nz(schema.enum)
  if type(enum) == "table" and #enum > 0 then
    local out = {}
    for _, value in ipairs(enum) do
      if type(value) == "string" then
        out[#out + 1] = { value = value, label = value }
      end
    end
    if #out > 0 then
      return out
    end
  end

  return nil
end

---Classify one property schema into a field descriptor (minus `key`/`required`).
---@param schema table
---@return { kind: string, options?: acp.ElicitationOption[], integer?: boolean }
local function classify(schema)
  local t = nz(schema.type)
  if t == "string" then
    local options = read_options(schema, "oneOf")
    if options then
      return { kind = "select", options = options }
    end
    return { kind = "text" }
  elseif t == "boolean" then
    return { kind = "boolean" }
  elseif t == "number" or t == "integer" then
    return { kind = "number", integer = t == "integer" }
  elseif t == "array" then
    local items = nz(schema.items)
    local options = type(items) == "table" and read_options(items, "anyOf") or nil
    -- An array with no enumerable items has no control we can render.
    if options then
      return { kind = "multi_select", options = options }
    end
    return { kind = "unsupported" }
  end
  return { kind = "unsupported" }
end

---Parse a `requestedSchema` into an ordered list of field descriptors.
---
---JSON object key order does not survive `vim.json.decode`, so order is
---recovered deterministically: required fields first (they gate the response),
---then the rest, each group sorted by key. Providers whose field names encode
---an intended order can reorder via a `transform` hook afterwards.
---@param schema table|nil
---@return acp.ElicitationField[]
function M.parse(schema)
  if type(schema) ~= "table" then
    return {}
  end
  local properties = nz(schema.properties)
  if type(properties) ~= "table" then
    return {}
  end

  local required = {} ---@type table<string, boolean>
  local required_list = nz(schema.required)
  if type(required_list) == "table" then
    for _, key in ipairs(required_list) do
      if type(key) == "string" then
        required[key] = true
      end
    end
  end

  local keys = {}
  for key in pairs(properties) do
    if type(key) == "string" then
      keys[#keys + 1] = key
    end
  end
  table.sort(keys, function(a, b)
    local ra, rb = required[a] or false, required[b] or false
    if ra ~= rb then
      return ra -- required first
    end
    return a < b
  end)

  local fields = {}
  for _, key in ipairs(keys) do
    local prop = properties[key]
    if type(prop) == "table" then
      local shape = classify(prop)
      fields[#fields + 1] = {
        key = key,
        kind = shape.kind,
        options = shape.options,
        integer = shape.integer,
        title = str(prop.title),
        description = str(prop.description),
        required = required[key] or false,
        default = nz(prop.default),
        meta = nz(prop._meta),
      }
    end
  end
  return fields
end

---Whether every required field has a usable answer. Empty strings and empty
---selections don't count — the user skipped, and the spec's `decline` action
---expresses that better than an accept carrying blanks.
---@param fields acp.ElicitationField[]
---@param answers table<string, any>
---@return boolean
function M.is_complete(fields, answers)
  for _, field in ipairs(fields) do
    if field.required then
      local v = answers[field.key]
      -- Typing a free-text answer satisfies the field it belongs to; the agent
      -- treats the companion as taking precedence over the selection.
      if field.custom_key then
        local custom = answers[field.custom_key]
        if type(custom) == "string" and custom ~= "" then
          v = custom
        end
      end
      if v == nil or v == "" then
        return false
      end
      if type(v) == "table" and #v == 0 then
        return false
      end
    end
  end
  return true
end

---Fold answers into the `content` object for an `accept` response.
---
---Only fields present in `answers` are emitted, and each value is coerced to
---the type its schema declared — the agent validates `content` against that
---schema, so a string where a number belongs is rejected. Unanswered fields and
---`unsupported` kinds are omitted rather than sent as null.
---@param fields acp.ElicitationField[]
---@param answers table<string, any>
---@return table content
function M.to_content(fields, answers)
  local content = {}
  for _, field in ipairs(fields) do
    -- A free-text companion is its own property in the requested schema even
    -- though a provider hook folds it into its sibling for display, and the
    -- agent reads it from there in preference to the selection. It must be
    -- emitted under its own key or the typed answer is silently dropped.
    if field.custom_key then
      local custom = answers[field.custom_key]
      if type(custom) == "string" and custom ~= "" then
        content[field.custom_key] = custom
      end
    end
    local v = answers[field.key]
    if v ~= nil and field.kind ~= "unsupported" then
      if field.kind == "multi_select" then
        if type(v) == "table" and #v > 0 then
          content[field.key] = v
        end
      elseif field.kind == "boolean" then
        content[field.key] = v and true or false
      elseif field.kind == "number" then
        local n = tonumber(v)
        if n then
          content[field.key] = field.integer and math.floor(n + 0.5) or n
        end
      else
        -- select / text: the wire type is string either way.
        local s = tostring(v)
        if s ~= "" then
          content[field.key] = s
        end
      end
    end
  end
  return content
end

return M
