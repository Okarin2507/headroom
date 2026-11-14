--!nonstrict
-- Google Antigravity (the `agy` CLI and the Antigravity apps share one quota).
--
-- Credentials: the Google session Antigravity saves through go-keyring, read
-- with `secret-tool lookup service gemini username antigravity` (Secret
-- Service), or the `agy` CLI's file ~/.gemini/antigravity-cli/antigravity-oauth-token.
-- Read-only, like every adapter.
--
-- Google access tokens live for an hour and only Antigravity can renew them, so
-- an expired session is handed back to Antigravity: we run `agy models` (the
-- lightest authenticated command; no prompt, no TTY), which makes agy refresh
-- its own keyring entry, then read it again (lib/renew: at most once per 10
-- minutes, so a dead session does not spawn agy on every refresh).
--
-- Endpoints, all on the daily host the CLI itself uses (the production host
-- reports stale Gemini numbers), all undocumented:
--   :loadCodeAssist            the plan name and the project to ask about (at
--                              most every 6 hours)
--   :retrieveUserQuotaSummary  every limit: Gemini's 5-hour and weekly, the
--                              Gemini 4 Argon weekly, Claude & GPT's. It only
--                              includes the Gemini groups for a client that
--                              identifies as a recent agy, and for a request
--                              that names the project from loadCodeAssist.
--   :fetchAvailableModels      each model's 5-hour quotaInfo; only a fallback
--                              for Gemini when the summary has none
-- It only answers clients that
-- identify as Antigravity, so this adapter's User-Agent is "antigravity"
-- rather than Headroom's own. Plans without Antigravity quota get 403
-- SUBSCRIPTION_REQUIRED, reported as no_plan rather than as a sign-in problem.

local provider = require("../../lib/provider.luau")
local model = require("../../lib/model.luau")
local time = require("../../lib/time.luau")
local jwt = require("../../lib/jwt.luau")
local renew = require("../../lib/renew.luau")

local E = model.ErrorCode

local CODE_ASSIST_URL = "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
local CLIENT_METADATA = '{"metadata":{"ideType":"ANTIGRAVITY","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}'
-- The plan changes rarely; ask for it at most this often.
local PLAN_TTL = 6 * 3600
local QUOTA_URL = "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
local MODELS_URL = "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels"
-- The service gates its Gemini groups on the client's User-Agent: a bare
-- "antigravity" gets Claude & GPT only, and so does an old agy version (1.0.0).
-- This is agy's own format; bump the version if Google starts rejecting it.
local USER_AGENT = "antigravity/cli/1.5.7 linux/amd64"
local SESSION_SECONDS = model.SESSION_SECONDS
local WEEK_SECONDS = model.WEEK_SECONDS

local KEYRING_LOOKUP = { "secret-tool", "lookup", "service", "gemini", "username", "antigravity" }
local TOKEN_FILE = "~/.gemini/antigravity-cli/antigravity-oauth-token"
local CLI_SETTINGS = "~/.gemini/antigravity-cli/settings.json"
local LOCAL_AGY = "~/.local/bin/agy"

-- Module state lives as long as the service.
local renewSession = renew.new(600, 30000)
-- A failed lookup may mean a locked keyring, and asking again could raise an
-- unlock prompt on every refresh. So after a failure the keyring rests for
-- KEYRING_BACKOFF and only the token file is read.
local KEYRING_BACKOFF = 30 * 60
local keyringFailedAt = -math.huge
local accountCache: { plan: string?, project: string?, at: number } = { plan = nil, project = nil, at = -math.huge }

type Session = { accessToken: string, expiry: any }

-- Accepts go-keyring's "go-keyring-base64:" wrapper, a { token = {...} }
-- envelope or a flat token object, with snake_case or camelCase keys.
local function parseSession(raw: string?, ctx): Session?
  if type(raw) ~= "string" then
    return nil
  end
  raw = raw:match("^%s*(.-)%s*$")
  local wrapped = raw:match("^go%-keyring%-base64:(.*)$")
  if wrapped then
    raw = jwt.base64Decode(wrapped)
    if raw == nil then
      return nil
    end
  end
  local data = ctx.decodeJson(raw)
  if type(data) ~= "table" then
    return nil
  end
  local token = if type(data.token) == "table" then data.token else data
  local access = token.access_token or token.accessToken
  if type(access) ~= "string" or access == "" then
    return nil
  end
  return { accessToken = access, expiry = token.expiry or token.expires_at or token.expiresAt }
end

local function readSession(ctx, done: (Session?) -> ())
  local function fromFile()
    local path = ctx.expandPath(TOKEN_FILE)
    if not ctx.fileExists(path) then
      done(nil)
      return
    end
    local raw = ctx.readFile(path)
    done(parseSession(raw, ctx))
  end
  if not ctx.which("secret-tool") or ctx.now() - keyringFailedAt < KEYRING_BACKOFF then
    fromFile()
    return
  end
  ctx.run(KEYRING_LOOKUP, 5000, function(result)
    local session = result and result.exitCode == 0 and parseSession(result.stdout, ctx) or nil
    if session then
      done(session)
    else
      keyringFailedAt = ctx.now()
      fromFile()
    end
  end)
end

local function agyCommand(ctx): string?
  return renew.findCommand(ctx, "agy", { LOCAL_AGY })
end

local function isFresh(session: Session?, now: number): boolean
  return session ~= nil and not time.isExpired(session.expiry, now)
end

-- Asks agy to renew its own session; done(true) when it ran successfully.
-- `env` sets one variable for this run only: agy otherwise may launch its
-- background updater.
local function renewWithAgy(ctx, done: (boolean) -> ())
  local agy = agyCommand(ctx)
  if agy == nil then
    done(false)
    return
  end
  renewSession(ctx, { "env", "AGY_CLI_DISABLE_AUTO_UPDATE=true", agy, "models" }, done)
end

-- "Gemini Models" -> "Gemini", "Claude and GPT models" -> "Claude & GPT"; a
-- model's own group ("Gemini 4 Argon") keeps its name.
local function groupLabel(name: any): string
  name = if type(name) == "string" then name else ""
  if name:find("Claude", 1, true) or name:find("GPT", 1, true) then
    return "Claude & GPT"
  elseif name:find("Gemini", 1, true) then
    local base = name:gsub("%s+[Mm]odels$", "")
    return if base == "Gemini" or base == "" then "Gemini" else base
  end
  return name
end

-- The panel lists windows in this order: Gemini first (session, then weekly),
-- then the other models' (session, then weekly). Stable otherwise.
local function sortWindows(windows: { model.Window })
  local function rank(w: model.Window): number
    local group = if w.label:sub(1, 6) == "Gemini" then 0 else 10
    return group + (if w.kind == "session" then 0 elseif w.kind == "weekly" then 1 else 2)
  end
  local position = {}
  for i, w in windows do
    position[w] = i
  end
  table.sort(windows, function(a, b)
    local ra, rb = rank(a), rank(b)
    if ra ~= rb then
      return ra < rb
    end
    return position[a] < position[b]
  end)
end

-- Exposed for tests: quota summary -> Snapshot. The API reports what is left;
-- every other provider reports what is spent, so it is inverted here.
local function parse(data, ctx): (model.Snapshot?, model.ProviderError?)
  local body = if type(data.response) == "table" then data.response else data
  local groups = body.groups
  if type(groups) ~= "table" then
    return nil, model.err(E.Parse, "no quota groups")
  end
  local windows = {}
  for _, group in groups do
    local label = groupLabel(group.displayName)
    for _, bucket in (if type(group.buckets) == "table" then group.buckets else {}) do
      local remaining = tonumber(bucket.remainingFraction)
      local id = tostring(bucket.bucketId or "")
      local cadence = bucket.window
      local weekly = cadence == "weekly" or id:sub(-6) == "weekly"
      local session = cadence == "5h" or id:sub(-2) == "5h"
      -- A missing fraction is unknown usage, not 0%: skip it rather than reassure.
      if remaining == nil or remaining ~= remaining or remaining < 0 or remaining > 1 or not (weekly or session) then
        continue
      end
      local kind = if weekly then "weekly" else "session"
      table.insert(windows, model.window({
        id = if id ~= "" then id else `{label}:{kind}`,
        kind = kind,
        label = `{label} · {ctx.tr(`window.{kind}`)}`,
        usedPercent = (1 - remaining) * 100,
        resetsAt = time.parseIso8601(bucket.resetTime),
        periodSeconds = if weekly then WEEK_SECONDS else SESSION_SECONDS,
      }))
    end
  end
  if #windows == 0 then
    return nil, model.err(E.Parse, "no usable quota buckets")
  end
  sortWindows(windows)
  return model.snapshot({ plan = nil, windows = windows, notes = {}, fetchedAt = ctx.now() }), nil
end

-- Gemini's limit from the model list. Every Gemini model carries the same
-- quotaInfo when they share one limit, so models are grouped by it: one window
-- per distinct (fraction, reset). Exposed for tests. Returns {} when the
-- response has no usable quotaInfo.
local function parseModels(data, ctx): { model.Window }
  local models = if type(data) == "table" then data.models else nil
  if type(models) ~= "table" then
    return {}
  end
  local buckets, order = {}, {}
  for id, entry in models do
    local quota = type(entry) == "table" and entry.quotaInfo or nil
    local remaining = type(quota) == "table" and tonumber(quota.remainingFraction) or nil
    local resetsAt = type(quota) == "table" and time.parseIso8601(quota.resetTime) or nil
    if
      type(id) == "string" and id:lower():find("gemini", 1, true)
      and remaining ~= nil and remaining == remaining and remaining >= 0 and remaining <= 1
      and resetsAt ~= nil
    then
      local key = `{remaining}|{resetsAt}`
      if buckets[key] == nil then
        buckets[key] = { remaining = remaining, resetsAt = resetsAt }
        table.insert(order, key)
      end
    end
  end
  table.sort(order) -- the same response always gives the same window order
  local windows = {}
  for i, key in order do
    local bucket = buckets[key]
    table.insert(windows, model.window({
      -- Stable across resets, so a reset is seen as one (notifications, pacing).
      id = if i == 1 then "gemini-5h" else `gemini-5h-{i}`,
      kind = "session",
      label = `Gemini · {ctx.tr("window.session")}`,
      usedPercent = (1 - bucket.remaining) * 100,
      resetsAt = bucket.resetsAt,
      periodSeconds = SESSION_SECONDS,
    }))
  end
  return windows
end

local function hasGemini(windows: { model.Window }): boolean
  for _, w in windows do
    if w.label:sub(1, 6) == "Gemini" then
      return true
    end
  end
  return false
end

-- Best effort, like the plan: a failure leaves Gemini out and never fails the fetch.
local function withGemini(ctx, headers, snapshot: model.Snapshot?, done: (model.Snapshot?) -> ())
  if snapshot ~= nil and hasGemini(snapshot.windows) then
    done(snapshot)
    return
  end
  ctx.postJson(MODELS_URL, headers, "{}", function(data, err)
    local windows = if err == nil then parseModels(data, ctx) else {}
    if #windows == 0 then
      done(snapshot)
      return
    end
    snapshot = snapshot or model.snapshot({ windows = {}, notes = {}, fetchedAt = ctx.now() })
    for _, w in windows do
      table.insert(snapshot.windows, w)
    end
    sortWindows(snapshot.windows)
    done(snapshot)
  end)
end

-- "Google AI Pro" from loadCodeAssist; paidTier wins over currentTier, which
-- reads "free-tier" even for paid Google AI accounts.
local function planFrom(data): string?
  for _, key in { "paidTier", "currentTier" } do
    local tier = data[key]
    if type(tier) == "table" and type(tier.name) == "string" and tier.name ~= "" then
      return tier.name
    end
  end
  return nil
end

-- The project loadCodeAssist assigns ("aicode-consumers" for consumer
-- accounts), which the quota request must name for the Gemini groups to appear.
-- Checked to be a plain identifier, since it goes into a JSON body.
local function projectFrom(data): string?
  local project = data.cloudaicompanionProject
  if type(project) == "table" then
    project = project.id
  end
  if type(project) == "string" and project:match("^[%w_.%-]+$") then
    return project
  end
  return nil
end

-- Plan and project, best effort: a failure leaves both unknown (the quota is
-- then asked for without a project) and never fails the fetch.
local function withAccount(ctx, headers, done: (string?, string?) -> ())
  if ctx.now() - accountCache.at < PLAN_TTL then
    done(accountCache.plan, accountCache.project)
    return
  end
  ctx.postJson(CODE_ASSIST_URL, headers, CLIENT_METADATA, function(data, err)
    if err == nil then
      accountCache = { plan = planFrom(data), project = projectFrom(data), at = ctx.now() }
    end
    done(accountCache.plan, accountCache.project)
  end)
end

-- Google answers 403 SUBSCRIPTION_REQUIRED when the account's plan has no
-- Antigravity quota: a plan problem, not a sign-in problem.
local function classify(status: number, body: string): string?
  if status == 403 and string.find(body, "SUBSCRIPTION_REQUIRED", 1, true) then
    return E.NoPlan
  end
  return nil
end

local function query(ctx, session: Session, done)
  local headers = {
    ["Authorization"] = `Bearer {session.accessToken}`,
    ["User-Agent"] = USER_AGENT, -- required by the endpoint; see USER_AGENT
  }
  withAccount(ctx, headers, function(plan, project)
    local body = if project then `\{"project":"{project}"}` else "{}"
    ctx.postJson(QUOTA_URL, headers, body, function(data, err)
      if err then
        done(nil, err)
        return
      end
      local snapshot, parseErr = parse(data, ctx)
      withGemini(ctx, headers, snapshot, function(complete)
        if complete == nil then
          done(nil, parseErr)
          return
        end
        complete.plan = plan
        done(complete, nil)
      end)
    end, classify)
  end)
end

return provider.define({
  id = "antigravity",
  name = "Antigravity",
  brand = {
    logo = "providers/antigravity/logo.svg",
    tint = "#4c8df6",
    glyph = "rocket",
  },

  -- Token analytics come from the conversation databases the CLI and the app
  -- keep (<folder>/*.db); see lib/analytics.luau.
  analytics = {
    source = "antigravity",
    folders = function(_ctx)
      return {
        "~/.gemini/antigravity-cli/conversations",
        "~/.gemini/antigravity/conversations",
        "~/.gemini/antigravity-ide/conversations",
      }
    end,
  },

  isConfigured = function(ctx)
    return ctx.fileExists(ctx.expandPath(CLI_SETTINGS))
      or ctx.fileExists(ctx.expandPath(TOKEN_FILE))
      or agyCommand(ctx) ~= nil
  end,

  signInHint = function(ctx)
    return ctx.tr("providers.antigravity.hint")
  end,

  fetch = function(ctx, done)
    readSession(ctx, function(session)
      if session == nil then
        done(nil, model.err(E.NotConfigured))
      elseif isFresh(session, ctx.now()) then
        query(ctx, session, done)
      else
        renewWithAgy(ctx, function(renewed)
          if not renewed then
            done(nil, model.err(E.Expired))
            return
          end
          readSession(ctx, function(again)
            if isFresh(again, ctx.now()) then
              query(ctx, again, done)
            else
              done(nil, model.err(E.Expired))
            end
          end)
        end)
      end
    end)
  end,

  parse = parse,
  parseModels = parseModels,
})
