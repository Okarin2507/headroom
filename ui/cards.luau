--!nonstrict
-- Card components: the provider card (accounts, windows, error banner, notes,
-- the add-account form), the disconnected row and the empty state, plus the
-- logo and caption used by the bar as well. Pure functions of their
-- arguments: the panel owns the state (which form is open, which removal is
-- being confirmed) and passes it in through `options`.

local theme = require("../lib/theme.luau")
local view = require("../lib/view.luau")
local time = require("../lib/time.luau")
local analytics = require("../lib/analytics.luau")

local M = {}

local CARD_FILL = "surface_variant/0.45"
local TRACK = "on_surface/0.10"

-- Errors the vendor's login fixes.
local SIGN_IN_ERRORS = { not_configured = true, expired = true, auth = true }

-- Panel options:
--   onOpenDashboard(url)?   shows the usage-page button when given
--   onRefresh()
--   onRefreshProvider(id)   fetches that provider's accounts now (button in its card)
--   onSignIn(key), onRemove(key), onCopy(key, text)
--   adding: string?         id of the provider whose add form is open
--   onAddOpen(id), onAddCancel(), onAddChange(text), onAddSubmit(id)
--   renaming: string?       key of the account whose name is being edited
--   onRenameOpen(key), onRenameCancel(), onRenameChange(text), onRenameSubmit(key)
--   confirmingRemove: string?, copied: string?   account keys
--   analyticsOpen: boolean?, onToggleAnalytics()   the token section; open unless false
export type Options = { [string]: any }

function M.logo(provider, size: number, opacity: number?)
  local path = theme.logo(provider)
  if path then
    return ui.image({ path = path, width = size, height = size, fit = "contain", opacity = opacity or 1 })
  end
  return ui.glyph({ name = provider.brand.glyph, size = size, color = "on_surface", opacity = opacity or 1 })
end

function M.caption(text: string, color: string?, extra)
  local props = { text = text, fontSize = 11, color = color or "on_surface_variant" }
  if extra then
    for k, v in extra do
      props[k] = v
    end
  end
  return ui.label(props)
end

local function needsSignIn(account): boolean
  return account.status == "absent" or (account.status == "error" and account.error ~= nil and SIGN_IN_ERRORS[account.error.code] == true)
end

local function signInButton(account, options, variant: string?)
  return ui.button({
    text = noctalia.tr(if account.signingIn then "accounts.sign_in_again" else "accounts.sign_in"),
    variant = variant or "outline",
    controlSize = "sm",
    tooltip = noctalia.tr("accounts.sign_in_tooltip"),
    onClick = function()
      options.onSignIn(account.key)
    end,
  })
end

local function windowRow(window, now: number, dimmed: boolean)
  local severity = view.severity(window, now)
  local paceText, paceColor, pace = view.pace(window, now)
  local resets = view.resetsIn(window, now)

  local children = {
    ui.row({ align = "center", gap = 8 }, {
      ui.label({ text = window.label, fontSize = 13, color = "on_surface", flexGrow = 1, maxLines = 1 }),
      ui.label({
        text = view.percent(window, view.showsRemaining()),
        fontSize = 13,
        fontWeight = "semibold",
        color = view.textColor(severity),
      }),
    }),
    ui.progress({
      progress = view.shownPercent(window) / 100,
      height = 8,
      radius = 4,
      fill = theme.meterColor(severity),
      track = TRACK,
    }),
  }

  if pace then
    -- The time track, on the same scale as the meter above it: time elapsed
    -- under a "used" meter, time remaining under a "left" one. A meter that
    -- outruns its track (used) or falls short of it (left) is burning fast.
    local remaining = view.showsRemaining()
    local fraction = if remaining then 1 - pace.elapsedFraction else pace.elapsedFraction
    table.insert(children, ui.column({
      tooltip = noctalia.tr(if remaining then "panel.remaining_tooltip" else "panel.elapsed_tooltip", {
        percent = math.floor(fraction * 100 + 0.5),
      }),
    }, {
      ui.progress({
        progress = fraction,
        height = 3,
        radius = 2,
        fill = "on_surface_variant/0.55",
        track = "on_surface/0.05",
      }),
    }))
  end

  if resets or paceText then
    table.insert(children, ui.row({ align = "center", gap = 8 }, {
      M.caption(resets or "", nil, { flexGrow = 1, maxLines = 1 }),
      M.caption(paceText or "", paceColor, { maxLines = 1 }),
    }))
  end

  return ui.column({ gap = 6, key = window.id, opacity = if dimmed then 0.6 else 1 }, children)
end

-- What failed and how to fix it; when older data is still shown below, says
-- how old it is. A sign-in problem offers the login itself; throttling offers
-- nothing, since retrying early only extends the wait.
local function errorBanner(account, now: number, options)
  local err = account.error
  local title = noctalia.tr(`error.{err.code}.title`)
  local body = err.hint or noctalia.tr(`error.{err.code}.body`)
  if account.snapshot and account.snapshot.fetchedAt then
    body = noctalia.tr("panel.showing_cached", { ago = time.ago(now - account.snapshot.fetchedAt) }) .. " " .. body
  end
  local action = if needsSignIn(account) and account.canSignIn
    then signInButton(account, options)
    elseif err.code == "rate_limited" then nil
    else ui.button({
      glyph = "refresh",
      variant = "ghost",
      controlSize = "sm",
      tooltip = noctalia.tr("panel.retry"),
      onClick = options.onRefresh,
    })
  return ui.row({ gap = 10, align = "center", padding = 10, radius = 10, fill = "error/0.12" }, {
    ui.glyph({ name = "alert-circle", size = 18, color = "error" }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = title, fontSize = 12, fontWeight = "semibold", color = "on_surface" }),
      M.caption(body, nil, { maxLines = 3 }),
    }),
    action,
  })
end

local function notesBlock(notes)
  local rows = {}
  for i, note in notes do
    table.insert(rows, ui.row({ align = "center", key = `note{i}` }, {
      M.caption(note.label, nil, { flexGrow = 1 }),
      ui.label({ text = note.value, fontSize = 11, fontWeight = "medium", color = "on_surface" }),
    }))
  end
  return ui.column({ gap = 4 }, rows)
end

-- One line on the account's state: plan, refreshing, cached, waiting.
local function accountStatus(account): string?
  local snapshot = account.snapshot
  if account.status == "absent" then
    return noctalia.tr(if account.signingIn then "accounts.waiting" else "accounts.not_signed_in")
  elseif account.busy then
    return noctalia.tr("status.refreshing")
  end
  local plan = snapshot and snapshot.plan or nil
  if account.stale and snapshot and account.status ~= "error" then
    return (if plan then plan .. " · " else "") .. noctalia.tr("status.cached")
  end
  return plan
end

-- ── Token analytics ────────────────────────────────────────────────────────

local CHART_HEIGHT = 44
local PERIODS = {
  { key = "session", label = "analytics.session" },
  { key = "today", label = "analytics.today" },
  { key = "week", label = "analytics.week" },
  { key = "month", label = "analytics.month" },
}

-- "In 2.3M · Out 970k", for tooltips.
local function inOut(totals): string
  return noctalia.tr("analytics.in_out", {
    input = analytics.compact(totals.input),
    output = analytics.compact(totals.output),
  })
end

-- "In 2.3M · Out 970k · 1157 responses", for tooltips.
local function breakdown(totals): string
  return noctalia.tr("analytics.breakdown", {
    input = analytics.compact(totals.input),
    output = analytics.compact(totals.output),
    messages = analytics.compact(totals.messages),
  })
end

-- In and Out sit in two right-aligned columns, so every figure lines up with
-- the heading above it.
local COLUMN = 64

local function numberCell(value: number, props)
  local cell = { text = analytics.compact(value), fontSize = 12, color = "on_surface", width = COLUMN, textAlign = "right", maxLines = 1 }
  for k, v in props or {} do
    cell[k] = v
  end
  return ui.label(cell)
end

-- A section title with the In / Out column headings on its right.
local function tableHeader(title: string)
  return ui.row({ align = "center", gap = 8 }, {
    M.caption(title, "on_surface", { flexGrow = 1, fontWeight = "semibold", maxLines = 1 }),
    M.caption(noctalia.tr("analytics.in"), nil, { width = COLUMN, textAlign = "right", fontWeight = "semibold" }),
    M.caption(noctalia.tr("analytics.out"), nil, { width = COLUMN, textAlign = "right", fontWeight = "semibold" }),
  })
end

local function periodRows(report)
  local rows = { tableHeader(noctalia.tr("analytics.period")), ui.separator({ color = "outline/0.2" }) }
  for _, period in PERIODS do
    local totals = report.periods[period.key]
    local strong = period.key == "session"
    local weight = if strong then "semibold" else "regular"
    table.insert(rows, ui.row({ key = period.key, align = "center", gap = 8, tooltip = breakdown(totals) }, {
      ui.label({ text = noctalia.tr(period.label), fontSize = 12, fontWeight = weight, color = "on_surface", flexGrow = 1, maxLines = 1 }),
      numberCell(totals.input, { fontWeight = weight }),
      numberCell(totals.output, { fontWeight = weight }),
    }))
  end
  return ui.column({ gap = 6 }, rows)
end

-- Seven bars, oldest first, today last and in full color, each with its day's
-- total (In + Out) above it. Each bar's tooltip gives the day's In and Out.
local function dayChart(days)
  local peak = 0
  for _, day in days do
    peak = math.max(peak, day.total)
  end
  local columns = {}
  for i, day in days do
    local height = if peak > 0 and day.total > 0 then math.max(3, math.floor(day.total / peak * CHART_HEIGHT + 0.5)) else 2
    local isToday = i == #days
    table.insert(columns, ui.column({
      key = day.date,
      flexGrow = 1,
      align = "center",
      justify = "end",
      gap = 3,
      height = CHART_HEIGHT + 30,
    }, {
      M.caption(if day.total > 0 then analytics.compact(day.total) else " ", if isToday then "on_surface" else nil, { fontSize = 9 }),
      ui.box({
        width = 18,
        height = height,
        radius = 3,
        fill = if day.total == 0 then "on_surface/0.10" elseif isToday then "primary" else "primary/0.5",
        tooltip = noctalia.tr("analytics.day_tooltip", { day = day.date, tokens = inOut(day) }),
      }),
      M.caption(day.weekday, if isToday then "on_surface" else nil, { fontSize = 10, fontWeight = if isToday then "semibold" else "regular" }),
    }))
  end
  return ui.column({ gap = 6 }, {
    M.caption(noctalia.tr("analytics.daily"), "on_surface", { fontWeight = "semibold" }),
    ui.row({ gap = 4, align = "end" }, columns),
  })
end

local function modelRows(report)
  local sum = 0
  for _, entry in report.models do
    sum += entry.total
  end
  local rows = { tableHeader(noctalia.tr("analytics.models")), ui.separator({ color = "outline/0.2" }) }
  for i, entry in report.models do
    if i > 4 then
      break
    end
    local share = if sum > 0 then entry.total / sum else 0
    table.insert(rows, ui.column({ key = entry.name, gap = 4, tooltip = breakdown(entry) }, {
      ui.row({ align = "center", gap = 8 }, {
        ui.label({ text = analytics.modelName(entry.name), fontSize = 12, color = "on_surface", flexGrow = 1, maxLines = 1 }),
        numberCell(entry.input),
        numberCell(entry.output),
      }),
      ui.progress({ progress = share, height = 3, radius = 2, fill = "primary/0.7", track = "on_surface/0.08" }),
    }))
  end
  return ui.column({ gap = 6 }, rows)
end

-- The account's token counts: this session, today, 7 and 30 days, the last
-- seven days as bars and the models behind them. Collapsible, since the usage
-- meters above are what most glances are for.
local function analyticsBlock(account, options)
  local report = account.analytics
  local open = options.analyticsOpen ~= false
  local children = {
    ui.row({ align = "center", gap = 6 }, {
      ui.label({ text = noctalia.tr("analytics.title"), fontSize = 12, fontWeight = "semibold", color = "on_surface", flexGrow = 1 }),
      ui.button({
        glyph = if open then "chevron-up" else "chevron-down",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr(if open then "analytics.collapse" else "analytics.expand"),
        onClick = function()
          options.onToggleAnalytics()
        end,
      }),
    }),
  }
  if open then
    if report.periods.month.messages == 0 then
      table.insert(children, M.caption(noctalia.tr("analytics.none"), nil, { maxLines = 2 }))
    else
      table.insert(children, periodRows(report))
      table.insert(children, dayChart(report.days))
      table.insert(children, modelRows(report))
      table.insert(children, M.caption(noctalia.tr("analytics.footnote"), "on_surface_variant/0.8", { fontSize = 10, maxLines = 3 }))
    end
  end
  return ui.column({ key = `analytics-{account.key}`, gap = 14 }, children)
end

-- Banner, meters and notes for one account.
local function accountBody(account, now: number, options): { any }
  local body = {}
  local snapshot = account.snapshot
  local dimmed = account.status == "error"
  if account.status == "error" and account.error then
    table.insert(body, errorBanner(account, now, options))
  end
  if account.status == "absent" then
    return body
  end
  if snapshot and #snapshot.windows > 0 then
    for _, window in snapshot.windows do
      table.insert(body, windowRow(window, now, dimmed))
    end
    if snapshot.notes and #snapshot.notes > 0 then
      table.insert(body, ui.separator({ color = "outline/0.25" }))
      table.insert(body, notesBlock(snapshot.notes))
    end
  elseif account.status == "loading" then
    table.insert(body, M.caption(noctalia.tr("status.fetching")))
  end
  if account.analytics then
    table.insert(body, ui.separator({ color = "outline/0.25" }))
    table.insert(body, analyticsBlock(account, options))
  end
  return body
end

-- Remove an added account (deletes its folder) or hide a found one; asks
-- again before acting.
local function removeButton(account, options)
  local hides = account.kind == "found"
  local confirming = options.confirmingRemove == account.key
  return ui.button({
    glyph = if confirming then nil else (if hides then "eye-off" else "trash"),
    text = if confirming then noctalia.tr(if hides then "accounts.hide_confirm" else "accounts.remove_confirm") else nil,
    variant = if confirming then "destructive" else "ghost",
    controlSize = "sm",
    tooltip = noctalia.tr(if hides then "accounts.hide_tooltip" else "accounts.remove_tooltip"),
    onClick = function()
      options.onRemove(account.key)
    end,
  })
end

-- Name, state and the account's own actions: sign in, copy the command that
-- starts the CLI as it, remove (asks again before acting).
local function accountHeader(provider, account, options)
  local details = {}
  if account.email then
    table.insert(details, account.email)
  end
  if account.kind == "default" then
    table.insert(details, noctalia.tr("accounts.default_tooltip", { provider = provider.name }))
  elseif account.home then
    table.insert(details, account.home)
  end

  local name = account.label or noctalia.tr("accounts.default")
  if options.renaming == account.key then
    local function submit()
      options.onRenameSubmit(account.key)
    end
    return ui.row({ align = "center", gap = 6 }, {
      ui.input({
        key = `rename-{account.key}`,
        value = account.label or "",
        placeholder = noctalia.tr("accounts.default"),
        controlSize = "sm",
        focus = true,
        flexGrow = 1,
        onChange = options.onRenameChange,
        onSubmit = function(text)
          options.onRenameChange(text)
          submit()
        end,
      }),
      ui.button({ glyph = "check", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("accounts.rename_save"), onClick = submit }),
      ui.button({ glyph = "x", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("accounts.cancel"), onClick = options.onRenameCancel }),
    })
  end

  local status = accountStatus(account)
  local children = {
    ui.row({ gap = 6, align = "center", flexGrow = 1, tooltip = if #details > 0 then table.concat(details, "\n") else nil }, {
      ui.label({ text = name, fontSize = 13, fontWeight = "semibold", color = "on_surface", maxLines = 1 }),
      M.caption(status or " ", nil, { visible = status ~= nil, maxLines = 1, flexGrow = 1 }),
    }),
  }

  if account.status == "absent" and account.canSignIn then
    table.insert(children, signInButton(account, options))
  end
  table.insert(children, ui.button({
    glyph = "pencil",
    variant = "ghost",
    controlSize = "sm",
    tooltip = noctalia.tr("accounts.rename_tooltip"),
    onClick = function()
      options.onRenameOpen(account.key, account.label or "")
    end,
  }))
  if account.launch then
    local copied = options.copied == account.key
    table.insert(children, ui.button({
      glyph = if copied then "check" else "terminal-2",
      variant = "ghost",
      controlSize = "sm",
      tooltip = noctalia.tr(if copied then "accounts.copied" else "accounts.copy_tooltip", { provider = provider.name }),
      onClick = function()
        options.onCopy(account.key, account.launch)
      end,
    }))
  end
  if account.kind ~= "default" then
    table.insert(children, removeButton(account, options))
  end
  return ui.row({ align = "center", gap = 6 }, children)
end

-- An account signed in to the same account as an earlier one: two folders,
-- one set of limits. One line under the folder's own name instead of the
-- numbers twice; signing in with another account or removing it fixes it.
local function duplicateRow(account, options)
  local children = {
    ui.glyph({ name = "copy", size = 14, color = "on_surface_variant" }),
    ui.row({
      gap = 6,
      align = "center",
      flexGrow = 1,
      tooltip = noctalia.tr("accounts.duplicate_body", { account = account.duplicateOf })
        .. (if account.home then "\n" .. account.home else ""),
    }, {
      ui.label({ text = account.label or noctalia.tr("accounts.default"), fontSize = 13, fontWeight = "semibold", color = "on_surface", maxLines = 1 }),
      M.caption(noctalia.tr("accounts.duplicate_title", { account = account.duplicateOf }), nil, { maxLines = 1, flexGrow = 1 }),
    }),
  }
  if account.canSignIn then
    table.insert(children, signInButton(account, options, "ghost"))
  end
  if account.kind ~= "default" then
    table.insert(children, removeButton(account, options))
  end
  return ui.row({ key = account.key, align = "center", gap = 6 }, children)
end

local function addForm(provider, options)
  local function submit()
    options.onAddSubmit(provider.id)
  end
  return ui.column({ key = `add-{provider.id}`, gap = 8, padding = 12, radius = 10, fill = "primary/0.08" }, {
    ui.label({ text = noctalia.tr("accounts.add_title", { provider = provider.name }), fontSize = 12, fontWeight = "semibold", color = "on_surface" }),
    ui.row({ gap = 6, align = "center" }, {
      ui.input({
        key = `add-input-{provider.id}`,
        placeholder = noctalia.tr("accounts.name_placeholder"),
        controlSize = "sm",
        focus = true,
        flexGrow = 1,
        onChange = options.onAddChange,
        onSubmit = function(text)
          options.onAddChange(text)
          submit()
        end,
      }),
      ui.button({ text = noctalia.tr("accounts.sign_in"), variant = "primary", controlSize = "sm", onClick = submit }),
      ui.button({
        glyph = "x",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("accounts.cancel"),
        onClick = options.onAddCancel,
      }),
    }),
    M.caption(noctalia.tr("accounts.add_help", { provider = provider.name }), nil, { maxLines = 4 }),
  })
end

-- A provider with its accounts. With one account the card reads as before:
-- the plan under the name, then the meters. With several, each account gets
-- a header of its own.
function M.providerCard(provider, now: number, options: Options)
  local accounts = provider.accounts
  local single = #accounts == 1 and accounts[1].kind == "default"

  local subtitle = if single
    then accountStatus(accounts[1])
    else noctalia.tr("accounts.count", { n = #accounts })
  -- With one account the card is that account: say who is signed in.
  local email = if single then accounts[1].email else nil
  local busy = false
  for _, account in accounts do
    busy = busy or account.busy == true
  end
  local headerChildren = {
    M.logo(provider, 22),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = provider.name, fontSize = 14, fontWeight = "semibold", color = "on_surface" }),
      M.caption(subtitle or " ", nil, { visible = subtitle ~= nil }),
      M.caption(email or " ", nil, { visible = email ~= nil, maxLines = 1 }),
    }),
  }
  if options.onRefreshProvider then
    table.insert(headerChildren, ui.button({
      glyph = "refresh",
      variant = "ghost",
      controlSize = "sm",
      enabled = not busy,
      tooltip = noctalia.tr("panel.refresh_provider_tooltip", { provider = provider.name }),
      onClick = function()
        options.onRefreshProvider(provider.id)
      end,
    }))
  end
  if provider.canAdd and options.adding ~= provider.id then
    table.insert(headerChildren, ui.button({
      glyph = "user-plus",
      variant = "ghost",
      controlSize = "sm",
      tooltip = noctalia.tr("accounts.add_tooltip", { provider = provider.name }),
      onClick = function()
        options.onAddOpen(provider.id)
      end,
    }))
  end
  if provider.brand.dashboard and options.onOpenDashboard then
    table.insert(headerChildren, ui.button({
      glyph = "external-link",
      variant = "ghost",
      controlSize = "sm",
      tooltip = noctalia.tr("panel.open_dashboard", { provider = provider.name }),
      onClick = function()
        options.onOpenDashboard(provider.brand.dashboard)
      end,
    }))
  end

  local body = { ui.row({ align = "center", gap = 10 }, headerChildren) }
  if options.adding == provider.id then
    table.insert(body, addForm(provider, options))
  end

  if single then
    for _, node in accountBody(accounts[1], now, options) do
      table.insert(body, node)
    end
  else
    for i, account in accounts do
      if i > 1 then
        table.insert(body, ui.separator({ color = "outline/0.25" }))
      end
      if account.duplicateOf then
        table.insert(body, duplicateRow(account, options))
      else
        local section = { accountHeader(provider, account, options) }
        for _, node in accountBody(account, now, options) do
          table.insert(section, node)
        end
        table.insert(body, ui.column({ key = account.key, gap = 10 }, section))
      end
    end
  end

  return ui.column({ key = provider.id, gap = 12, padding = 14, radius = 14, fill = CARD_FILL }, body)
end

-- A provider whose only account isn't signed in.
function M.disconnectedRow(provider, options: Options)
  local account = provider.accounts[1]
  local children = {
    M.logo(provider, 18, 0.5),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = noctalia.tr("panel.not_connected", { provider = provider.name }), fontSize = 12, color = "on_surface_variant" }),
      M.caption(if account.signingIn then noctalia.tr("accounts.waiting") else provider.hint, "on_surface_variant/0.8", { maxLines = 2 }),
    }),
  }
  if account.canSignIn then
    table.insert(children, signInButton(account, options))
  end
  return ui.row({ key = `off-{provider.id}`, align = "center", gap = 10, padding = 10, radius = 12, border = "outline/0.25", borderWidth = 1 }, children)
end

function M.emptyState()
  return ui.column({ flexGrow = 1, gap = 10, align = "center", justify = "center", padding = 24 }, {
    ui.glyph({ name = "gauge", size = 40, color = "on_surface_variant" }),
    ui.label({ text = noctalia.tr("panel.empty_title"), fontSize = 15, fontWeight = "semibold", color = "on_surface" }),
    ui.label({ text = noctalia.tr("panel.empty_body"), fontSize = 12, color = "on_surface_variant", textAlign = "center", maxLines = 4 }),
  })
end

return M
