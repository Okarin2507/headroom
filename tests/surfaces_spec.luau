--!nonstrict
local t = require("./support/t")
local env = require("./support/env")

-- Antigravity's quota summary: Gemini's session is 51% used, its weekly 20%.
local function antigravityBody(host)
  return host.globals.noctalia.json.encode({
    groups = { {
      displayName = "Gemini Models",
      buckets = {
        { bucketId = "gemini-5h", window = "5h", resetTime = "2026-10-03T06:19:59Z", remainingFraction = 0.49 },
        { bucketId = "gemini-weekly", window = "weekly", resetTime = "2026-10-10T06:19:59Z", remainingFraction = 0.8 },
      },
    } },
  })
end

-- Claude and Antigravity signed in, the service running.
local function running(opts)
  opts = opts or {}
  local host = env.host()
  env.claudeCreds(host)
  env.antigravityAuth(host)
  env.serve(host, {
    ["api.anthropic.com"] = env.claudeBody(host, opts.claudeSession),
    ["loadCodeAssist"] = '{"paidTier":{"name":"Google AI Pro"}}',
    ["retrieveUserQuotaSummary"] = opts.antigravityResponse or antigravityBody(host),
  })
  for k, v in opts.config or {} do
    host.config[k] = v
  end
  local svc = env.start(host, "service.luau")
  return host, svc
end

local function firstLabel(tree)
  return env.ofType(tree, "label")[1].props
end

local function openPanel(host)
  local panel = env.start(host, "panel.luau")
  panel.call("onOpen", "")
  return panel, env.texts(host.panelTree)
end

t.group("bar", function()
  t.test("logo, ring and value per signed-in provider", function()
    local host = running({ config = { window = "tightest" } })
    env.start(host, "bar.luau")
    local texts = env.texts(host.barTree)
    -- Claude's tightest window is weekly (47%), Antigravity's is the session (51%).
    t.contains(texts, "47%")
    t.contains(texts, "51%")
    local images = env.ofType(host.barTree, "image")
    t.eq(#images, 4)
    t.ok(host.files[images[1].props.path]:find('fill="#d97757"', 1, true) ~= nil, "logo tinted with the brand color")
    t.ok(host.files[images[2].props.path]:find('stroke="#88aaff"', 1, true) ~= nil, "healthy ring in the theme primary")
    t.ok(images[2].props.path:find("/data/rings/ring%-47%-") ~= nil, images[2].props.path)
  end)

  t.test("bar style: percentage only", function()
    local host = running({ config = { bar_style = "value" } })
    env.start(host, "bar.luau")
    t.eq(#env.ofType(host.barTree, "image"), 2, "logos only, no rings")
  end)

  t.test("the bar shows the 5-hour session by default", function()
    local host = running()
    env.start(host, "bar.luau")
    local texts = env.texts(host.barTree)
    t.contains(texts, "38%") -- Claude's session; its weekly window is at 47%
    t.contains(texts, "51%") -- Antigravity's Gemini session
    t.eq(host.tooltip[1].key, "Claude · Session")
  end)

  t.test("weekly can still be chosen", function()
    local host = running({ config = { window = "weekly" } })
    env.start(host, "bar.luau")
    t.contains(env.texts(host.barTree), "47%")
    t.eq(host.tooltip[1].key, "Claude · Weekly")
  end)

  t.test("tooltip: one short row per fact", function()
    local host = running({ config = { window = "tightest" } })
    host.clock = 1791100799 - 2 * 86400 -- Claude weekly 5/7 elapsed
    env.start(host, "bar.luau")
    local rows = host.tooltip
    t.eq(rows[1].key, "Claude · Weekly")
    t.eq(rows[1].value, "47% used")
    t.eq(rows[2].value, "2d · Sun 07:59")
    t.eq(rows[3].value, "≈ 66% by reset")
  end)

  t.test("panel-only providers stay out of the bar", function()
    local host = running({ config = { provider_claude = "panel" } })
    env.start(host, "bar.luau")
    t.eq(table.concat(env.texts(host.barTree), ","), "51%")
  end)

  t.test("max_providers keeps the most urgent", function()
    local host = running({ claudeSession = 88, config = { max_providers = 1 } })
    env.start(host, "bar.luau")
    t.eq(table.concat(env.texts(host.barTree), ","), "88%")
  end)

  t.test("remaining mode inverts numbers and rings, not colors", function()
    local host = running({ claudeSession = 95, config = { provider_antigravity = "panel", window = "session", display = "remaining" } })
    env.start(host, "bar.luau")
    t.eq(firstLabel(host.barTree).text, "5%")
    t.eq(firstLabel(host.barTree).color, "error", "severity follows usage")
    t.ok(env.ofType(host.barTree, "image")[2].props.path:find("ring%-5%-") ~= nil)
    t.eq(host.tooltip[1].value, "5% left")
  end)

  t.test("forecast raises the color before the threshold", function()
    local host = running({ claudeSession = 60, config = { provider_antigravity = "panel", window = "session" } })
    host.clock = 1791058799 - 3 * 3600 -- 2h in, 60% used: locked out for 1h40m
    env.start(host, "bar.luau")
    t.eq(firstLabel(host.barTree).color, "#f2b84b")
    t.eq(host.tooltip[3].value, "Runs out in 1h 20m")
  end)

  t.test("a maxed-out window shows when it comes back", function()
    local host = running({ claudeSession = 100, config = { provider_antigravity = "panel", window = "session" } })
    host.clock = 1791058799 - 4500
    env.start(host, "bar.luau")
    t.eq(firstLabel(host.barTree).text, "1h 15m")
  end)

  t.test("vertical bars drop the percent sign", function()
    local host = running({ config = { provider_claude = "panel" } })
    host.vertical = true
    env.start(host, "bar.luau")
    t.eq(host.barTree.type, "column")
    t.contains(env.texts(host.barTree), "51")
  end)

  t.test("follows the report as it changes", function()
    local host, svc = running({ config = { provider_antigravity = "panel", window = "session" } })
    env.start(host, "bar.luau")
    env.serve(host, {
      ["api.anthropic.com"] = env.claudeBody(host, 77),
      ["loadCodeAssist"] = '{"paidTier":{"name":"Google AI Pro"}}',
      ["retrieveUserQuotaSummary"] = antigravityBody(host),
    })
    svc.call("onIpc", "refresh")
    t.contains(env.texts(host.barTree), "77%")
  end)

  t.test("empty state when nothing is signed in", function()
    local host = env.host()
    env.start(host, "service.luau")
    env.start(host, "bar.luau")
    t.eq(env.ofType(host.barTree, "glyph")[1].props.name, "gauge")
  end)
end)

-- Presses a provider's button at the top right of the panel.
local function switchTo(host, name)
  local node = env.find(host.panelTree, function(n)
    return n.props.tooltip == name and tostring(n.props.key):find("switch-", 1, true) ~= nil
  end)[1]
  t.ok(node ~= nil, `a switch for {name}`)
  t.ok(#env.ofType(node, "image") + #env.ofType(node, "glyph") > 0, "it shows the provider's logo")
  node.props.onClick()
  return env.texts(host.panelTree)
end

t.group("panel", function()
  t.test("one provider at a time; buttons at the top right switch between them", function()
    local host = running()
    local _, texts = openPanel(host)
    for _, text in { "Claude", "Team 5x", "Weekly · Fable", "38%" } do
      t.contains(texts, text)
    end
    t.eq(table.find(texts, "Google AI Pro"), nil, "the other provider's card is not shown")
    t.ok(#env.ofType(host.panelTree, "progress") >= 3, "a meter per window")
    texts = switchTo(host, "Antigravity")
    for _, text in { "Antigravity", "Google AI Pro" } do
      t.contains(texts, text)
    end
    t.eq(table.find(texts, "Team 5x"), nil)
    texts = switchTo(host, "Claude")
    t.contains(texts, "Team 5x")
  end)

  t.test("a single connected provider needs no switch", function()
    local host = running({ config = { provider_antigravity = "off" } })
    openPanel(host)
    local switches = env.find(host.panelTree, function(n)
      return tostring(n.props.key):find("switch-", 1, true) ~= nil
    end)
    t.eq(#switches, 0, "no switch")
  end)

  t.test("a card shows who is signed in and has its own refresh button", function()
    local host = running()
    openPanel(host)
    local texts = switchTo(host, "Antigravity")
    t.contains(texts, "dev@example.com")
    local function withTooltip(text)
      for _, n in env.ofType(host.panelTree, "button") do
        if n.props.tooltip == text then
          return n
        end
      end
      return nil
    end
    local btn = withTooltip("Refresh Antigravity now")
    t.ok(btn ~= nil, "refresh button on the Antigravity card")
    local before = #host.requests
    btn.props.onClick()
    t.eq(host.stateValues.command.provider, "antigravity")
    t.ok(#host.requests > before, "the provider is fetched right away")
  end)

  t.test("reset clock, projection and remaining mode", function()
    local host = running({ config = { display = "remaining" } })
    host.clock = 1791100799 - 2 * 86400 -- weekly: 5 of 7 days elapsed
    local _, texts = openPanel(host)
    t.contains(texts, "Resets in 2d · Sun 07:59")
    t.contains(texts, "≈ 34% left at reset") -- Claude weekly: 47% used, ~66% by reset
  end)

  t.test("the time track matches the meter's direction", function()
    local host = running()
    host.clock = 1791058799 - 4 * 3600 -- Claude session: 1h of 5h elapsed
    openPanel(host)
    local function track()
      for _, n in env.ofType(host.panelTree, "progress") do
        if n.props.height == 3 then
          return n.props.progress
        end
      end
      return nil
    end
    t.near(track(), 0.2, 1e-6, "used: time elapsed")
    host.config.display = "remaining"
    openPanel(host)
    t.near(track(), 0.8, 1e-6, "remaining: time left")
  end)

  t.test("error banner explains how to recover", function()
    local host = running({ antigravityResponse = { ok = true, status = 401, body = "" } })
    openPanel(host)
    local texts = switchTo(host, "Antigravity")
    t.contains(texts, "Sign-in rejected")
    t.contains(texts, "Run `agy` once and sign in with Google.")
  end)

  t.test("disconnected providers and the empty state", function()
    local host = env.host()
    env.start(host, "service.luau")
    local _, texts = openPanel(host)
    t.contains(texts, "No signed-in providers")
    t.contains(texts, "Antigravity · not connected")
  end)

  t.test("a card has no add-account or usage-page buttons", function()
    local host = running()
    openPanel(host)
    for _, glyph in { "user-plus", "external-link" } do
      t.eq(#env.find(host.panelTree, function(n) return n.props.glyph == glyph end), 0, glyph)
    end
  end)

  t.test("opening fetches data that is old enough, once", function()
    local host = running()
    local panel = openPanel(host)
    local before = #host.requests
    host.clock += 601 -- Claude is not asked sooner than every 10 minutes
    panel.call("onClose")
    panel.call("onOpen", "")
    panel.call("onClose")
    panel.call("onOpen", "")
    t.eq(#host.requests, before + 2)
  end)
end)

t.group("accounts", function()
  local WORK = "/home/test/.claude-work"

  -- Claude signed in twice: the default at 38% session, ~/.claude-work at 88%.
  local function twoClaudeAccounts(config)
    local host = env.host()
    host.commands["claude"] = true
    env.claudeCreds(host)
    env.claudeCreds(host, { accessToken = "work-token" }, WORK)
    host.httpHandler = function(req)
      local work = env.headerOf(req, "Authorization") == "Bearer work-token"
      return { ok = true, status = 200, body = env.claudeBody(host, if work then 88 else 38) }
    end
    for k, v in config or {} do
      host.config[k] = v
    end
    env.start(host, "service.luau")
    return host
  end

  local function button(tree, predicate)
    return env.find(tree, function(n) return n.type == "button" and predicate(n.props) end)[1]
  end

  t.test("the bar shows the default account unless asked for every account", function()
    local host = twoClaudeAccounts({ window = "session" })
    env.start(host, "bar.luau")
    t.eq(table.concat(env.texts(host.barTree), ","), "38%")
    t.eq(host.tooltip[1].key, "Claude · Default · Session")

    host.config.bar_accounts = "all"
    env.start(host, "bar.luau")
    t.eq(table.concat(env.texts(host.barTree), ","), "38%,88%")
    local keys = {}
    for _, row in host.tooltip do
      table.insert(keys, row.key)
    end
    t.contains(keys, "Claude · work · Session")
  end)

  t.test("the bar leaves out an account signed in to one already shown", function()
    local host = env.host()
    host.commands["claude"] = true
    host.config.bar_accounts = "all"
    host.config.window = "session"
    env.claudeCreds(host)
    env.claudeProfile(host, "me")
    host.httpHandler = function()
      return { ok = true, status = 200, body = env.claudeBody(host, 38) }
    end
    local svc = env.start(host, "service.luau")
    host.globals.noctalia.state.set("command", { action = "add", provider = "claude", label = "Work" })
    env.claudeCreds(host, nil, "/data/accounts/claude/work")
    env.claudeProfile(host, "me", "/data/accounts/claude/work")
    host.clock += 5
    svc.call("update")
    env.start(host, "bar.luau")
    t.eq(table.concat(env.texts(host.barTree), ","), "38%")
  end)

  t.test("the panel gives each account its own section", function()
    local host = twoClaudeAccounts()
    local _, texts = openPanel(host)
    for _, text in { "Claude", "2 accounts", "Default", "work", "38%", "88%" } do
      t.contains(texts, text)
    end
  end)

  t.test("removing asks twice", function()
    local host = twoClaudeAccounts()
    openPanel(host)
    local hide = button(host.panelTree, function(p) return p.glyph == "eye-off" end)
    hide.props.onClick()
    t.eq(#host.stateValues.report.providers[1].accounts, 2, "first click only asks")
    button(host.panelTree, function(p) return p.text == "Hide?" end).props.onClick()
    t.eq(#host.stateValues.report.providers[1].accounts, 1)
  end)

  t.test("renaming from the panel", function()
    local host = twoClaudeAccounts()
    openPanel(host)
    button(host.panelTree, function(p) return p.glyph == "pencil" end).props.onClick()
    local input = env.ofType(host.panelTree, "input")[1]
    input.props.onSubmit("Personal")
    t.contains(env.texts(host.panelTree), "Personal")
    t.eq(#env.ofType(host.panelTree, "input"), 0, "editor closed")
  end)

  t.test("copying gives the command that starts the CLI as the account", function()
    local host = twoClaudeAccounts()
    openPanel(host)
    button(host.panelTree, function(p) return p.glyph == "terminal-2" end).props.onClick()
    t.eq(host.clipboard, "CLAUDE_CONFIG_DIR='/home/test/.claude-work' claude")
  end)

  t.test("a provider that isn't signed in offers the sign-in", function()
    local host = env.host()
    host.commands["claude"] = true
    env.start(host, "service.luau")
    openPanel(host)
    local row = env.find(host.panelTree, function(n) return n.props.key == "off-claude" end)[1]
    button(row, function(p) return p.text == "Sign in" end).props.onClick()
    t.eq(host.terminals[1]:find("'claude' 'auth' 'login'", 1, true) ~= nil, true, host.terminals[1])
    t.eq(host.terminals[1]:find("CLAUDE_CONFIG_DIR", 1, true), nil, "the default account signs in where the CLI looks")
  end)
end)

return true
