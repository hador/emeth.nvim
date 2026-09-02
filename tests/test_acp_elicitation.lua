local h = require("tests.helpers")
local Elicit = require("emeth.acp.elicitation")
local ClaudeCode = require("emeth.integrations.claude-code")

--- Index parsed fields by key for order-independent assertions.
---@param fields acp.ElicitationField[]
local function by_key(fields)
  local out = {}
  for _, f in ipairs(fields) do
    out[f.key] = f
  end
  return out
end

h.describe("acp.elicitation.parse — property types", function()
  h.it("reads a titled oneOf as a single-select with labels and descriptions", function()
    local fields = Elicit.parse({
      type = "object",
      properties = {
        lib = {
          type = "string",
          title = "Library",
          oneOf = {
            { const = "date-fns", title = "date-fns", description = "tree-shakeable" },
            { const = "luxon", title = "Luxon" },
          },
        },
      },
    })
    h.eq(1, #fields)
    h.eq("select", fields[1].kind)
    h.eq("Library", fields[1].title)
    h.eq(2, #fields[1].options)
    h.eq("date-fns", fields[1].options[1].value)
    h.eq("tree-shakeable", fields[1].options[1].description)
    -- No title on the second option: the wire value stands in as the label.
    h.eq("Luxon", fields[1].options[2].label)
  end)

  h.it("reads a bare enum as a single-select", function()
    local fields = Elicit.parse({
      type = "object",
      properties = { pick = { type = "string", enum = { "a", "b" } } },
    })
    h.eq("select", fields[1].kind)
    h.eq({ "a", "b" }, { fields[1].options[1].value, fields[1].options[2].value })
  end)

  h.it("reads an array of anyOf as a multi-select", function()
    local fields = Elicit.parse({
      type = "object",
      properties = {
        feats = {
          type = "array",
          items = { anyOf = { { const = "x", title = "X" }, { const = "y", title = "Y" } } },
        },
      },
    })
    h.eq("multi_select", fields[1].kind)
    h.eq(2, #fields[1].options)
  end)

  h.it("classifies plain primitives", function()
    local f = by_key(Elicit.parse({
      type = "object",
      properties = {
        s = { type = "string" },
        b = { type = "boolean" },
        n = { type = "number" },
        i = { type = "integer" },
      },
    }))
    h.eq("text", f.s.kind)
    h.eq("boolean", f.b.kind)
    h.eq("number", f.n.kind)
    h.eq("number", f.i.kind)
    h.is_true(f.i.integer, "integer fields must round before going on the wire")
    h.eq(false, f.n.integer)
  end)

  h.it("marks unknown and unenumerable types unsupported, not renderable controls", function()
    local f = by_key(Elicit.parse({
      type = "object",
      properties = {
        custom = { type = "_futureThing" },
        loose = { type = "array" }, -- array with no enumerable items
      },
    }))
    h.eq("unsupported", f.custom.kind)
    h.eq("unsupported", f.loose.kind)
  end)

  h.it("returns no fields for a missing or malformed schema", function()
    h.eq({}, Elicit.parse(nil))
    h.eq({}, Elicit.parse({ type = "object" }))
    h.eq({}, Elicit.parse({ type = "object", properties = vim.NIL }))
  end)
end)

h.describe("acp.elicitation.parse — JSON null handling", function()
  h.it("treats vim.NIL fields as absent", function()
    local fields = Elicit.parse({
      type = "object",
      properties = {
        q = {
          type = "string",
          title = vim.NIL,
          description = vim.NIL,
          default = vim.NIL,
          oneOf = { { const = "a", title = "A", description = vim.NIL } },
        },
      },
      required = vim.NIL,
    })
    h.is_nil(fields[1].title)
    h.is_nil(fields[1].description)
    h.is_nil(fields[1].default)
    h.is_nil(fields[1].options[1].description)
    h.eq(false, fields[1].required)
  end)

  h.it("skips enum options with no const, which could not be sent back", function()
    local fields = Elicit.parse({
      type = "object",
      properties = { q = { type = "string", oneOf = { { title = "no const" }, { const = "ok", title = "Ok" } } } },
    })
    h.eq(1, #fields[1].options)
    h.eq("ok", fields[1].options[1].value)
  end)
end)

h.describe("acp.elicitation.parse — ordering", function()
  h.it("puts required fields first, then sorts by key", function()
    local fields = Elicit.parse({
      type = "object",
      properties = {
        zeta = { type = "string" },
        alpha = { type = "string" },
        needed = { type = "string" },
      },
      required = { "needed" },
    })
    h.eq({ "needed", "alpha", "zeta" }, { fields[1].key, fields[2].key, fields[3].key })
  end)
end)

h.describe("acp.elicitation.is_complete", function()
  local fields = Elicit.parse({
    type = "object",
    properties = { a = { type = "string" }, b = { type = "string" } },
    required = { "a" },
  })

  h.it("is complete when required fields are answered", function()
    h.is_true(Elicit.is_complete(fields, { a = "x" }))
  end)

  h.it("is incomplete when a required field is missing or blank", function()
    h.eq(false, Elicit.is_complete(fields, {}))
    h.eq(false, Elicit.is_complete(fields, { a = "" }))
  end)

  h.it("treats an empty multi-select as unanswered", function()
    local multi = Elicit.parse({
      type = "object",
      properties = { m = { type = "array", items = { anyOf = { { const = "x", title = "X" } } } } },
      required = { "m" },
    })
    h.eq(false, Elicit.is_complete(multi, { m = {} }))
    h.is_true(Elicit.is_complete(multi, { m = { "x" } }))
  end)

  h.it("ignores unanswered optional fields", function()
    h.is_true(Elicit.is_complete(fields, { a = "x" }), "b is optional")
  end)
end)

h.describe("acp.elicitation.to_content — wire value types", function()
  local fields = Elicit.parse({
    type = "object",
    properties = {
      s = { type = "string" },
      b = { type = "boolean" },
      n = { type = "number" },
      i = { type = "integer" },
      m = { type = "array", items = { anyOf = { { const = "x", title = "X" } } } },
      bad = { type = "_unknown" },
    },
  })

  h.it("coerces each value to the type its schema declared", function()
    local content = Elicit.to_content(fields, {
      s = "text",
      b = true,
      n = "1.5",
      i = "3.7",
      m = { "x" },
    })
    h.eq("text", content.s)
    h.eq(true, content.b)
    h.eq(1.5, content.n)
    -- Integer fields must not send a float; the agent validates against the schema.
    h.eq(4, content.i)
    h.eq({ "x" }, content.m)
  end)

  h.it("omits unanswered fields rather than sending nulls", function()
    local content = Elicit.to_content(fields, { s = "only" })
    h.eq({ s = "only" }, content)
  end)

  h.it("omits blank strings and empty multi-selects", function()
    h.eq({}, Elicit.to_content(fields, { s = "", m = {} }))
  end)

  h.it("omits unsupported fields even when an answer is somehow present", function()
    h.eq({}, Elicit.to_content(fields, { bad = "nope" }))
  end)

  h.it("normalizes falsey booleans to false rather than dropping them", function()
    h.eq({ b = false }, Elicit.to_content(fields, { b = false }))
  end)
end)

h.describe("claude-code transform_elicitation", function()
  --- The shape claude-acp actually sends for AskUserQuestion: one select field
  --- per question, each followed by a `_custom` free-text companion.
  local function ask_schema(n)
    local properties = {}
    for i = 0, n - 1 do
      properties["question_" .. i] = {
        type = "string",
        title = "Header " .. i,
        oneOf = {
          {
            const = "opt-a",
            title = "Option A",
            description = "does a",
            _meta = { ["_claude/askUserQuestionOption"] = { preview = "code for a" } },
          },
          { const = "opt-b", title = "Option B", description = "does b" },
        },
      }
      properties["question_" .. i .. "_custom"] = {
        type = "string",
        title = "Other",
        _meta = { _askUserQuestionCustomAnswer = { questionId = "question_" .. i, isCustomAnswer = true } },
      }
    end
    return { type = "object", properties = properties }
  end

  h.it("folds the custom-answer companion into its question", function()
    local fields = ClaudeCode._transform_elicitation(Elicit.parse(ask_schema(1)))
    h.eq(1, #fields, "the companion is folded away, not rendered as its own prompt")
    h.eq("question_0", fields[1].key)
    h.eq("question_0_custom", fields[1].custom_key)
  end)

  h.it("lifts an option preview out of the claude _meta namespace", function()
    local fields = ClaudeCode._transform_elicitation(Elicit.parse(ask_schema(1)))
    h.eq("code for a", fields[1].options[1].preview)
    h.is_nil(fields[1].options[2].preview)
  end)

  h.it("orders questions numerically, not lexicographically", function()
    -- parse() sorts by key, which puts question_10 before question_2.
    local fields = ClaudeCode._transform_elicitation(Elicit.parse(ask_schema(11)))
    local keys = {}
    for _, f in ipairs(fields) do
      keys[#keys + 1] = f.key
    end
    h.eq("question_0", keys[1])
    h.eq("question_2", keys[3])
    h.eq("question_10", keys[11])
    h.eq(11, #keys)
  end)

  h.it("falls back to the _custom name suffix when the _meta marker is absent", function()
    local fields = ClaudeCode._transform_elicitation(Elicit.parse({
      type = "object",
      properties = {
        question_0 = { type = "string", oneOf = { { const = "a", title = "A" } } },
        question_0_custom = { type = "string", title = "Other" },
      },
    }))
    h.eq(1, #fields)
    h.eq("question_0_custom", fields[1].custom_key)
  end)

  h.it("leaves a generic MCP form untouched", function()
    local parsed = Elicit.parse({
      type = "object",
      properties = { token = { type = "string" }, remember = { type = "boolean" } },
    })
    local fields = ClaudeCode._transform_elicitation(parsed)
    h.eq(2, #fields)
    for _, f in ipairs(fields) do
      h.is_nil(f.custom_key)
    end
  end)
end)
