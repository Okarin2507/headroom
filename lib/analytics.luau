--!nonstrict
-- Token analytics: how many tokens an account has used in the current 5-hour
-- session, today, the last 7 and 30 days, by model and by day.
--
-- The vendors' usage endpoints only report percentages. The token counts live
-- on disk, in what the CLIs already keep (Claude Code's transcripts, Antigravity's
-- conversation databases). A short read-only Python program (analytics_script)
-- adds them up out of process, so a large history never blocks the shell, and
-- prints one small JSON document that parse() checks and normalizes.
--
-- Providers opt in with `analytics = { source, folders }` (see lib/provider.luau).
-- Side effects, for review: spawns `python3 -I -c <script>`; reads only the
-- folders the provider names; writes nothing.

local script = require("./analytics_script.luau")

local M = {}

M.COMMAND = "python3"
local TIMEOUT_MS = 60000

-- The numbers one period (or model, or day) carries.
--   total        input + output
--   input        prompt tokens the model read anew (not re-served from the prompt cache)
--   output       generated tokens, thinking included
--   messages     model responses
export type Totals = {
  total: number,
  input: number,
  output: number,
  messages: number,
}

export type Report = {
  generatedAt: number,
  sessionStart: number, -- Unix seconds the "session" period starts from
  lastActivity: number, -- 0 when nothing was used in the last 30 days
  sessions: number, -- conversations touched in the last 7 days
  periods: { session: Totals, today: Totals, day: Totals, week: Totals, month: Totals }, -- day = the last 24 hours
  models: { (Totals & { name: string }) }, -- last 7 days, busiest first
  modelsDay: { (Totals & { name: string }) }, -- last 24 hours, busiest first
  modelsMonth: { (Totals & { name: string }) }, -- last 30 days, busiest first
  days30: { (Totals & { date: string, weekday: string }) }, -- last 30 days, oldest first
  hours: { (Totals & { hour: string }) }, -- last 24 clock hours, oldest first ("14" = 14:00)
  days: { (Totals & { date: string, weekday: string }) }, -- last 7 days, oldest first
}

local function num(value: any): number
  local n = tonumber(value)
  if n == nil or n ~= n or n < 0 then
    return 0
  end
  return n
end

local function totals(raw: any): Totals
  raw = if type(raw) == "table" then raw else {}
  local input, output = num(raw.input), num(raw.output)
  return {
    total = input + output,
    input = input,
    output = output,
    messages = num(raw.messages),
  }
end

local function withField(raw: any, key: string, fallback: string): any
  local t = totals(raw)
  t[key] = if type(raw) == "table" and type(raw[key]) == "string" then raw[key] else fallback
  return t
end

-- The script's JSON -> Report, or nil when it is not one.
function M.parse(data: any): Report?
  if type(data) ~= "table" or type(data.periods) ~= "table" then
    return nil
  end
  local models, modelsDay, modelsMonth, days, hours, days30 = {}, {}, {}, {}, {}, {}
  for _, model in (if type(data.models) == "table" then data.models else {}) do
    table.insert(models, withField(model, "name", "?"))
  end
  for _, model in (if type(data.modelsDay) == "table" then data.modelsDay else {}) do
    table.insert(modelsDay, withField(model, "name", "?"))
  end
  for _, model in (if type(data.modelsMonth) == "table" then data.modelsMonth else {}) do
    table.insert(modelsMonth, withField(model, "name", "?"))
  end
  for _, day in (if type(data.days30) == "table" then data.days30 else {}) do
    local entry = withField(day, "date", "")
    entry.weekday = if type(day) == "table" and type(day.weekday) == "string" then day.weekday else ""
    table.insert(days30, entry)
  end
  for _, hour in (if type(data.hours) == "table" then data.hours else {}) do
    table.insert(hours, withField(hour, "hour", ""))
  end
  for _, day in (if type(data.days) == "table" then data.days else {}) do
    local entry = withField(day, "date", "")
    entry.weekday = if type(day) == "table" and type(day.weekday) == "string" then day.weekday else ""
    table.insert(days, entry)
  end
  return {
    generatedAt = num(data.generatedAt),
    sessionStart = num(data.sessionStart),
    lastActivity = num(data.lastActivity),
    sessions = num(data.sessions),
    periods = {
      session = totals(data.periods.session),
      today = totals(data.periods.today),
      day = totals(data.periods.day),
      week = totals(data.periods.week),
      month = totals(data.periods.month),
    },
    models = models,
    modelsDay = modelsDay,
    modelsMonth = modelsMonth,
    days30 = days30,
    days = days,
    hours = hours,
  }
end

-- Whether the machine can run the analytics at all.
function M.available(ctx): boolean
  return ctx.which(M.COMMAND)
end

-- Runs the analytics for one account. `spec` is the provider's `analytics`,
-- `sessionStart` (Unix seconds, optional) where its current session began.
-- done(report) on success, done(nil) when python3 is missing or it failed.
function M.collect(ctx, spec, sessionStart: number?, done: (Report?) -> ())
  if not M.available(ctx) then
    done(nil)
    return
  end
  local argv = { M.COMMAND, "-I", "-c", script, spec.source, tostring(math.floor(sessionStart or 0)) }
  for _, folder in spec.folders(ctx) do
    table.insert(argv, ctx.expandPath(folder))
  end
  ctx.run(argv, TIMEOUT_MS, function(result)
    if result == nil or result.exitCode ~= 0 then
      done(nil)
      return
    end
    local ok, data = pcall(ctx.decodeJson, result.stdout)
    done(if ok then M.parse(data) else nil)
  end)
end

-- "950", "12.3k", "984k", "1.2M", "34M", "2.1B": three significant figures at most.
function M.compact(value: number): string
  value = math.max(0, math.floor(value + 0.5))
  local function scaled(divisor: number, suffix: string): string
    local n = value / divisor
    return (if n < 10 then string.format("%.1f", n) else string.format("%d", math.floor(n + 0.5))) .. suffix
  end
  if value < 1000 then
    return tostring(value)
  elseif value < 999500 then
    return scaled(1e3, "k")
  elseif value < 999500000 then
    return scaled(1e6, "M")
  end
  return scaled(1e9, "B")
end

-- "claude-opus-5-5" -> "Opus 5.5", "claude-haiku-4-5-20251001" -> "Haiku 4.5";
-- names that are already readable ("Gemini 4 Hydrogen") pass through.
function M.modelName(name: string): string
  local family, major, minor = name:match("^claude%-(%a+)%-(%d+)%-(%d)")
  if family == nil then
    family, major = name:match("^claude%-(%a+)%-(%d+)")
  end
  if family then
    local label = family:sub(1, 1):upper() .. family:sub(2) .. " " .. major
    return if minor then `{label}.{minor}` else label
  end
  return (name:gsub("^claude%-", ""))
end

return M
