--!nonstrict
local t = require("./support/t")
local env = require("./support/env")

local fetch, byId = env.fetch, env.byId

t.group("claude", function()
  t.test("parses the live response", function()
    local host, claude, ctx = env.provider("claude")
    local data = host.globals.noctalia.json.decode(env.fixture("claude_usage.json"))
    local snap = claude.parse(data, { subscriptionType = "team", rateLimitTier = "default_claude_max_5x" }, ctx)
    t.eq(snap.plan, "Team 5x")
    local w = byId(snap.windows)
    t.eq(w.session.usedPercent, 38)
    t.eq(w.session.kind, "session")
    t.eq(w.session.resetsAt, 1791058799)
    t.eq(w.weekly.usedPercent, 47)
    t.eq(w["weekly_scoped:Fable"].label, "Weekly · Fable")
    t.eq(#snap.notes, 0, "extra usage disabled -> no note")
  end)

  t.test("reports extra usage spend", function()
    local host, claude, ctx = env.provider("claude")
    local data = host.globals.noctalia.json.decode(env.fixture("claude_usage.json"))
    data.extra_usage.is_enabled = true
    data.spend.used = { amount_minor = 1230, exponent = 2, currency = "USD" }
    data.spend.limit = { amount_minor = 5000, exponent = 2, currency = "USD" }
    t.eq(claude.parse(data, {}, ctx).notes[1].value, "$12.30 of $50.00")
  end)

  t.test("signed in -> authenticated GET with the beta header", function()
    local host, claude, ctx = env.provider("claude")
    env.claudeCreds(host)
    env.serve(host, { ["api.anthropic.com"] = env.fixture("claude_usage.json") })
    local snap, err = fetch(claude, ctx)
    t.eq(err, nil)
    t.eq(#snap.windows, 3)
    local req = host.requests[1]
    t.eq(req.url, "https://api.anthropic.com/api/oauth/usage")
    t.eq(env.headerOf(req, "Authorization"), "Bearer claude-token")
    t.eq(env.headerOf(req, "anthropic-beta"), "oauth-2025-04-20")
    t.eq(env.headerOf(req, "User-Agent"), "headroom-noctalia/test")
  end)

  t.test("no credentials, or an expiring token: no request", function()
    local host, claude, ctx = env.provider("claude")
    t.eq(claude.isConfigured(ctx), false)
    t.eq(select(2, fetch(claude, ctx)).code, "not_configured")
    env.claudeCreds(host, { expiresAt = (host.clock + 30) * 1000 }) -- inside the safety margin
    t.eq(select(2, fetch(claude, ctx)).code, "expired")
    t.eq(#host.requests, 0)
  end)

  t.test("expired -> Claude Code renews its own session, then we read it again", function()
    local host, claude, ctx = env.provider("claude")
    host.commands["claude"] = true
    env.claudeCreds(host, { expiresAt = (host.clock - 60) * 1000 })
    host.runHandler = function(argv)
      if table.concat(argv, " ") == "claude -p /status --no-session-persistence" then
        env.claudeCreds(host) -- what Claude Code does: a fresh token in its own file
        return { exitCode = 0, stdout = "" }
      end
      return nil
    end
    env.serve(host, { ["api.anthropic.com"] = env.fixture("claude_usage.json") })
    local snap, err = fetch(claude, ctx)
    t.eq(err, nil)
    t.eq(#snap.windows, 3)
    t.eq(#host.spawned, 1)
  end)

  t.test("renewal that does not help: expired, and not retried within the cooldown", function()
    local host, claude, ctx = env.provider("claude")
    host.commands["claude"] = true
    env.claudeCreds(host, { expiresAt = (host.clock - 60) * 1000 })
    host.runHandler = function()
      return { exitCode = 0, stdout = "" }
    end
    t.eq(select(2, fetch(claude, ctx)).code, "expired")
    t.eq(select(2, fetch(claude, ctx)).code, "expired")
    t.eq(#host.spawned, 1)
    t.eq(#host.requests, 0)
  end)

  t.test("another account renews in its own folder; a found one is left to its owner", function()
    local host, claude = env.provider("claude")
    host.commands["claude"] = true
    local added = "/data/accounts/claude/side"
    env.claudeCreds(host, { expiresAt = (host.clock - 60) * 1000 }, added)
    host.runHandler = function(argv)
      if table.concat(argv, " ") == `env CLAUDE_CONFIG_DIR={added} claude -p /status --no-session-persistence` then
        env.claudeCreds(host, nil, added)
        return { exitCode = 0, stdout = "" }
      end
      return nil
    end
    env.serve(host, { ["api.anthropic.com"] = env.fixture("claude_usage.json") })
    local _, err = fetch(claude, env.context(host, claude, { kind = "added", home = added }))
    t.eq(err, nil)

    local found = "/home/test/.claude-work"
    env.claudeCreds(host, { expiresAt = (host.clock - 60) * 1000 }, found)
    t.eq(select(2, fetch(claude, env.context(host, claude, { kind = "found", home = found }))).code, "expired")
    t.eq(#host.spawned, 1, "no renewal in a found folder")
  end)

  t.test("honors CLAUDE_CONFIG_DIR", function()
    local host, claude = env.provider("claude")
    host.env.CLAUDE_CONFIG_DIR = "/work/claude"
    host.files["/work/claude/.credentials.json"] = "{}"
    t.eq(claude.isConfigured(env.context(host, claude)), true)
  end)
end)

t.group("antigravity", function()
  local KEYRING = "secret-tool lookup service gemini username antigravity"
  local RENEW = "env AGY_CLI_DISABLE_AUTO_UPDATE=true agy models"
  local FRESH = "2026-09-21T15:00:00Z" -- host clock is 2026-09-21T14:13:20Z
  local STALE = "2026-09-21T14:00:00Z"

  local function session(expiry: string)
    return `\{"token":\{"access_token":"ya29.test","refresh_token":"r","expiry":"{expiry}"}}`
  end

  -- agy installed, secret-tool answering with `keyring`, the quota endpoint
  -- answering with `quota` (a body, or a response table).
  local function setup(opts)
    local host, p, ctx = env.provider("antigravity")
    host.commands["secret-tool"] = opts.secretTool ~= false
    host.commands["agy"] = opts.agy ~= false
    local keyring = opts.keyring
    host.runHandler = function(argv)
      local line = table.concat(argv, " ")
      if line == KEYRING then
        return { exitCode = if keyring then 0 else 1, stdout = keyring or "" }
      elseif line == RENEW then
        keyring = if opts.onRenew then opts.onRenew() else keyring
        return { exitCode = 0, stdout = "" }
      end
      return nil
    end
    env.serve(host, {
      ["loadCodeAssist"] = '{"paidTier":{"name":"Google AI Pro"}}',
      ["retrieveUserQuotaSummary"] = opts.quota or env.fixture("antigravity_quota.json"),
      ["fetchAvailableModels"] = opts.models,
    })
    return host, p, ctx
  end

  local function commands(host)
    local out = {}
    for _, argv in host.spawned do
      table.insert(out, table.concat(argv, " "))
    end
    return out
  end

  t.test("parses the live response: remaining inverted to used", function()
    local host, p, ctx = env.provider("antigravity")
    local w = byId(p.parse(host.globals.noctalia.json.decode(env.fixture("antigravity_quota.json")), ctx).windows)
    t.eq(w["gemini-weekly"].label, "Gemini · Weekly")
    t.near(w["gemini-weekly"].usedPercent, 0.0346, 1e-6)
    t.eq(w["gemini-weekly"].periodSeconds, 7 * 86400)
    t.eq(w["3p-5h"].label, "Claude & GPT · Session")
  end)

  t.test("Gemini's windows come first, session before weekly, then the other models'", function()
    local host, p, ctx = env.provider("antigravity")
    local snap = p.parse(host.globals.noctalia.json.decode(env.fixture("antigravity_quota.json")), ctx)
    local ids = {}
    for _, w in snap.windows do
      table.insert(ids, w.id)
    end
    t.eq(table.concat(ids, ","), "gemini-5h,gemini-weekly,3p-5h,3p-weekly")
  end)

  t.test("a Gemini window found in the model list also goes first", function()
    local _, p, ctx = setup({
      keyring = session(FRESH),
      quota = env.fixture("antigravity_quota_3p_only.json"),
      models = env.fixture("antigravity_models.json"),
    })
    local snap = fetch(p, ctx)
    local ids = {}
    for _, w in snap.windows do
      table.insert(ids, w.id)
    end
    t.eq(table.concat(ids, ","), "gemini-5h,3p-5h,3p-weekly")
  end)

  t.test("a bucket without a valid fraction is skipped, never shown as 0%", function()
    local _, p, ctx = env.provider("antigravity")
    local snap = p.parse({ groups = { { displayName = "Gemini Models", buckets = {
      { bucketId = "gemini-5h", window = "5h", resetTime = FRESH },
      { bucketId = "gemini-weekly", window = "weekly", remainingFraction = 1.7 },
      { bucketId = "gemini-weekly", window = "weekly", remainingFraction = 0.25 },
    } } } }, ctx)
    t.eq(#snap.windows, 1)
    t.eq(snap.windows[1].usedPercent, 75)
  end)

  t.test("fresh session -> POST as antigravity, plan from loadCodeAssist", function()
    local host, p, ctx = setup({ keyring = session(FRESH) })
    local snap, err = fetch(p, ctx)
    t.eq(err, nil)
    t.eq(#snap.windows, 4)
    t.eq(snap.plan, "Google AI Pro")
    local req = host.requests[1]
    t.eq(req.method, "POST")
    t.eq(env.headerOf(req, "User-Agent"), "antigravity")
    t.eq(commands(host)[1], KEYRING)
  end)

  t.test("Gemini's shared limit comes from the model list when the summary leaves it out", function()
    local host, p, ctx = setup({
      keyring = session(FRESH),
      quota = env.fixture("antigravity_quota_3p_only.json"),
      models = env.fixture("antigravity_models.json"),
    })
    local snap, err = fetch(p, ctx)
    t.eq(err, nil)
    local w = byId(snap.windows)
    t.eq(#snap.windows, 3, "two Claude & GPT windows plus one Gemini")
    t.eq(w["gemini-5h"].label, "Gemini · Session")
    t.eq(w["gemini-5h"].kind, "session")
    t.near(w["gemini-5h"].usedPercent, 47.261155, 1e-5)
    t.eq(w["gemini-5h"].resetsAt, 1790009031)
    t.eq(w["gemini-5h"].periodSeconds, 5 * 3600)
    local urls = {}
    for _, req in host.requests do
      table.insert(urls, req.url)
    end
    t.ok(table.concat(urls, " "):find("daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels", 1, true) ~= nil, "asks the CLI's host")
  end)

  t.test("the model list is not asked for when the summary already has Gemini, and its failure is harmless", function()
    local host, p, ctx = setup({ keyring = session(FRESH), models = env.fixture("antigravity_models.json") })
    local snap = fetch(p, ctx)
    t.eq(#snap.windows, 4)
    for _, req in host.requests do
      t.ok(req.url:find("fetchAvailableModels", 1, true) == nil, "not requested")
    end

    local _, p2, ctx2 = setup({ keyring = session(FRESH), quota = env.fixture("antigravity_quota_3p_only.json") })
    local snap2, err2 = fetch(p2, ctx2) -- the models route answers 404
    t.eq(err2, nil)
    t.eq(#snap2.windows, 2)
  end)

  t.test("models without a usable quota never become a window", function()
    local _, p, ctx = env.provider("antigravity")
    t.eq(#p.parseModels({ models = { ["gemini-3-flash"] = { quotaInfo = { remainingFraction = 1.5, resetTime = FRESH } } } }, ctx), 0)
    t.eq(#p.parseModels({ models = { ["gemini-3-flash"] = { quotaInfo = { resetTime = FRESH } } } }, ctx), 0, "no fraction is unknown, not 0%")
    t.eq(#p.parseModels({ models = { ["claude-opus-5-5-low"] = { quotaInfo = { remainingFraction = 0.5, resetTime = FRESH } } } }, ctx), 0)
    t.eq(#p.parseModels({}, ctx), 0)
    t.eq(#p.parseModels(nil, ctx), 0)
  end)

  t.test("go-keyring base64 wrapping and the CLI token file are understood", function()
    local _, p, ctx = setup({ keyring = "go-keyring-base64:eyJhY2Nlc3NUb2tlbiI6InlhMjkudGVzdCIsImV4cGlyZXNBdCI6MTc5MDAwMzYwMDAwMH0=" })
    t.eq(select(2, fetch(p, ctx)), nil, "base64-wrapped camelCase session, epoch-ms expiry")

    local host2, p2, ctx2 = setup({ secretTool = false })
    host2.files["/home/test/.gemini/antigravity-cli/antigravity-oauth-token"] = session(FRESH)
    t.eq(select(2, fetch(p2, ctx2)), nil, "token file without secret-tool")
    t.eq(#host2.spawned, 0)
  end)

  t.test("expired -> agy renews its own session, then we read it again", function()
    local host, p, ctx = setup({ keyring = session(STALE), onRenew = function() return session(FRESH) end })
    local _, err = fetch(p, ctx)
    t.eq(err, nil)
    t.eq(table.concat(commands(host), " | "), `{KEYRING} | {RENEW} | {KEYRING}`)
  end)

  t.test("renewal that does not help is not retried within the cooldown", function()
    local host, p, ctx = setup({ keyring = session(STALE) })
    t.eq(select(2, fetch(p, ctx)).code, "expired")
    t.eq(select(2, fetch(p, ctx)).code, "expired")
    t.eq(table.concat(commands(host), " | "), `{KEYRING} | {RENEW} | {KEYRING} | {KEYRING}`)
    t.eq(#host.requests, 0)
  end)

  t.test("a failed keyring lookup rests the keyring instead of prompting again", function()
    local host, p, ctx = setup({})
    t.eq(select(2, fetch(p, ctx)).code, "not_configured")
    fetch(p, ctx)
    t.eq(#commands(host), 1)
  end)

  t.test("SUBSCRIPTION_REQUIRED is a plan problem, not a sign-in problem", function()
    local _, p, ctx = setup({
      keyring = session(FRESH),
      quota = { ok = true, status = 403, body = '{"error":{"details":[{"reason":"SUBSCRIPTION_REQUIRED"}]}}' },
    })
    t.eq(select(2, fetch(p, ctx)).code, "no_plan")
  end)
end)

return true
