--!nonstrict
local t = require("./support/t")
local env = require("./support/env")

local host0 = env.host()
local mods = env.modules(host0)
local analytics = mods.require("lib/analytics.luau")
local model = mods.require("lib/model.luau")

-- What the Python program prints, for a day of Claude Code use.
local function scriptOutput(host)
  local function totals(input, output, messages)
    return { input = input, output = output, messages = messages }
  end
  local days = {}
  for i, name in { "Fri", "Sat", "Sun", "Mon", "Tue", "Wed", "Thu" } do
    local day = totals(0, if i == 7 then 4000 else 0, if i == 7 then 3 else 0)
    day.date = `2026-09-{20 + i}`
    day.weekday = name
    table.insert(days, day)
  end
  return host.globals.noctalia.json.encode({
    generatedAt = 1790000000,
    sessionStart = 1789990000,
    lastActivity = 1789999000,
    sessions = 2,
    periods = {
      session = totals(2300000, 970000, 1157),
      today = totals(2500000, 1012000, 1243),
      week = totals(9000000, 3969000, 4374),
      month = totals(9000000, 3969000, 4374),
    },
    models = {
      { name = "claude-opus-5-5", input = 6000000, output = 2000000, messages = 2455 },
      { name = "claude-sonnet-5-5", input = 600000, output = 1180000, messages = 1344 },
    },
    days = days,
  })
end

-- Claude signed in, python3 present and answering the analytics program.
local function running(opts)
  opts = opts or {}
  local host = env.host()
  env.claudeCreds(host)
  env.serve(host, { ["api.anthropic.com"] = env.claudeBody(host) })
  host.commands["python3"] = opts.python ~= false
  host.analyticsRuns = {}
  host.runHandler = function(argv)
    if argv[1] == "python3" then
      table.insert(host.analyticsRuns, argv)
      return { exitCode = 0, stdout = opts.stdout or scriptOutput(host) }
    end
    return nil
  end
  for k, v in opts.config or {} do
    host.config[k] = v
  end
  return host, env.start(host, "service.luau")
end

local function claudeAccount(host)
  local report = host.globals.noctalia.state.get("report")
  return report.providers[1].accounts[1]
end

t.group("analytics", function()
  t.test("compact numbers keep three figures", function()
    t.eq(analytics.compact(0), "0")
    t.eq(analytics.compact(950), "950")
    t.eq(analytics.compact(1234), "1.2k")
    t.eq(analytics.compact(98765), "99k")
    t.eq(analytics.compact(999600), "1.0M")
    t.eq(analytics.compact(5261338), "5.3M")
    t.eq(analytics.compact(129164315), "129M")
    t.eq(analytics.compact(2100000000), "2.1B")
  end)

  t.test("model names read well", function()
    t.eq(analytics.modelName("claude-opus-5-5"), "Opus 5.5")
    t.eq(analytics.modelName("claude-haiku-4-5-20251001"), "Haiku 4.5")
    t.eq(analytics.modelName("claude-fable-5"), "Fable 5")
    t.eq(analytics.modelName("Gemini 4 Hydrogen"), "Gemini 4 Hydrogen")
  end)

  t.test("parse normalizes the script's output and rejects anything else", function()
    t.eq(analytics.parse(nil), nil)
    t.eq(analytics.parse({ nope = true }), nil)
    local report = analytics.parse(host0.globals.noctalia.json.decode(scriptOutput(host0)))
    t.eq(report.periods.session.input, 2300000)
    t.eq(report.periods.session.output, 970000)
    t.eq(report.periods.session.total, 3270000, "total = input + output")
    t.eq(report.periods.session.cacheRead, nil, "cache is not tracked")
    t.eq(report.models[1].name, "claude-opus-5-5")
    t.eq(#report.days, 7)
    t.eq(report.days[7].weekday, "Thu")
    local junk = analytics.parse({ periods = { session = { input = -5, output = "x" } } })
    t.eq(junk.periods.session.total, 0, "negative and non-numeric counts are zero")
  end)

  t.test("the session picks the tightest of several session windows", function()
    local picked = model.pick({
      model.window({ id = "a", kind = "session", usedPercent = 10 }),
      model.window({ id = "b", kind = "session", usedPercent = 60 }),
      model.window({ id = "w", kind = "weekly", usedPercent = 90 }),
    }, "session")
    t.eq(picked.id, "b")
    t.eq(model.pick({ model.window({ id = "w", kind = "weekly", usedPercent = 90 }) }, "session").id, "w", "no session window: falls back")
  end)

  t.test("the service runs the program per account and publishes the report", function()
    local host = running()
    local account = claudeAccount(host)
    t.ok(account.analytics ~= nil, "analytics published")
    t.eq(account.analytics.periods.session.messages, 1157)
    local argv = host.analyticsRuns[1]
    t.eq(argv[2], "-I")
    t.eq(argv[3], "-c")
    t.eq(argv[5], "claude")
    t.eq(argv[#argv], "/home/test/.claude", "reads the account's own folder")
    -- The session began one session length before its reset.
    local session = account.snapshot.windows[1]
    t.eq(tonumber(argv[6]), session.resetsAt - model.SESSION_SECONDS)
  end)

  t.test("it is not run again before it is due, and runs again on a manual refresh", function()
    local host, svc = running()
    t.eq(#host.analyticsRuns, 1)
    host.clock += 30
    svc.call("update")
    t.eq(#host.analyticsRuns, 1, "not due")
    host.globals.noctalia.state.set("command", { action = "refresh" })
    t.eq(#host.analyticsRuns, 2, "refresh asks again")
  end)

  t.test("opencode shows token usage only, and the bar leaves it out", function()
    local host = env.host()
    host.files["/home/test/.local/share/opencode/opencode.db"] = "x"
    host.commands["python3"] = true
    host.analyticsRuns = {}
    host.runHandler = function(argv)
      if argv[1] == "python3" then
        table.insert(host.analyticsRuns, argv)
        return { exitCode = 0, stdout = scriptOutput(host) }
      end
      return nil
    end
    host.config.provider_opencode = "bar"
    env.start(host, "service.luau")
    local opencode
    for _, view in host.globals.noctalia.state.get("report").providers do
      if view.id == "opencode" then
        opencode = view.accounts[1]
      end
    end
    t.eq(opencode.status, "ok")
    t.eq(opencode.analytics.periods.session.input, 2300000)
    t.eq(host.analyticsRuns[1][5], "opencode")
    t.eq(host.analyticsRuns[1][7], "/home/test/.local/share/opencode")
    env.start(host, "bar.luau")
    t.eq(#env.ofType(host.barTree, "image"), 0, "no ring: there is no limit to show")
    local panel = env.start(host, "panel.luau")
    panel.call("onOpen", "")
    t.contains(env.texts(host.panelTree), "opencode")
    t.contains(env.texts(host.panelTree), "Token usage")
  end)

  t.test("the token analytics setting turns it off", function()
    local host = running({ config = { analytics = false } })
    t.eq(#host.analyticsRuns, 0, "nothing spawned")
    t.eq(claudeAccount(host).analytics, nil)
  end)

  t.test("without python3, or when it fails, the account is left as it was", function()
    local host = running({ python = false })
    t.eq(#host.analyticsRuns, 0)
    t.eq(claudeAccount(host).analytics, nil)
    t.eq(claudeAccount(host).status, "ok", "usage meters are unaffected")

    local broken = running({ stdout = "not json" })
    t.eq(claudeAccount(broken).analytics, nil)
    t.eq(claudeAccount(broken).status, "ok")
  end)

  t.test("the panel shows the periods, the chart and the models; they can be collapsed", function()
    local host = running()
    local panel = env.start(host, "panel.luau")
    panel.call("onOpen", "")
    local texts = env.texts(host.panelTree)
    t.contains(texts, "Token usage")
    t.contains(texts, "This 5-hour session")
    t.contains(texts, "2.3M") -- In
    t.contains(texts, "970k") -- Out
    t.contains(texts, "In")
    t.contains(texts, "Out")
    for _, text in texts do
      t.ok(not text:lower():find("cache", 1, true) or text:find("Counted from", 1, true) ~= nil, "no cache figures: " .. text)
    end
    t.contains(texts, "Opus 5.5")
    t.contains(texts, "Thu")

    local toggle
    for _, button in env.ofType(host.panelTree, "button") do
      if button.props.glyph == "chevron-up" then
        toggle = button
      end
    end
    t.ok(toggle ~= nil, "a collapse button")
    toggle.props.onClick()
    local collapsed = env.texts(host.panelTree)
    t.contains(collapsed, "Token usage")
    for _, text in collapsed do
      t.ok(text ~= "This 5-hour session", "section is collapsed")
    end
  end)

  t.test("the bar tooltip gives the session's tokens", function()
    local host = running()
    env.start(host, "bar.luau")
    local row
    for _, r in host.tooltip do
      if r.key == "Tokens" then
        row = r
      end
    end
    t.ok(row ~= nil, "a Tokens row")
    t.eq(row.value, "In 2.3M · Out 970k this session")
  end)
end)

return true
