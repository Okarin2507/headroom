--!nonstrict
-- The Overview tab: token usage of every provider side by side, over the last
-- 24 hours or the last 7 days.
--
--   total and responses, the providers' shares, a chart stacked by provider,
--   In / Out totals, and a breakdown by model.
--
-- Pure functions of the published report (lib/analytics.luau Reports, one per
-- account); the panel owns which range is shown and passes it in `options`.

local analytics = require("../lib/analytics.luau")
local cards = require("./cards.luau")

local M = {}

local CHART_HEIGHT = 64
local MODEL_ROWS = 6
local COLUMN = 64

-- The two ranges the tab can show: the report's period, models and chart for each.
local RANGES = {
  ["24h"] = { period = "day", models = "modelsDay", series = "hours", label = "overview.range_24h", chart = "overview.hourly" },
  ["30d"] = { period = "month", models = "modelsMonth", series = "days30", label = "overview.range_30d", chart = "overview.daily" },
  ["7d"] = { period = "week", models = "models", series = "days", label = "overview.range_7d", chart = "overview.daily" },
}
M.RANGE_KEYS = { "24h", "7d", "30d" }

local function add(into, from)
  into.input += from.input
  into.output += from.output
  into.messages += from.messages
  into.total += from.total
end

local function blank()
  return { input = 0, output = 0, messages = 0, total = 0 }
end

-- Sums the reports of a provider's accounts (a copy of an account already
-- listed is skipped: its numbers are the same).
local function reportsOf(provider): { any }
  local reports = {}
  for _, account in provider.accounts or {} do
    if account.analytics and account.duplicateOf == nil then
      table.insert(reports, account.analytics)
    end
  end
  return reports
end

-- Everything the tab shows for `rangeKey`:
--   total: Totals                    all providers
--   providers: { { provider, totals } }   busiest first, only those with usage
--   series: { { label, total, parts = { [providerId] = tokens }, input, output } }
--   models: { { provider, name, totals } }   busiest first
function M.collect(providers, rangeKey: string)
  local range = RANGES[rangeKey] or RANGES["24h"]
  local total = blank()
  local rows, series, models = {}, {}, {}
  for _, provider in providers do
    local sum = blank()
    for _, report in reportsOf(provider) do
      add(sum, report.periods[range.period])
      for i, bucket in report[range.series] do
        local slot = series[i]
        if slot == nil then
          slot = {
            label = bucket.hour or bucket.weekday or "",
            -- the axis line under a long chart: "14:00" or "11-19"
            axis = if bucket.hour then `{bucket.hour}:00` else (bucket.date or ""):sub(6),
            date = bucket.date,
            total = 0, input = 0, output = 0, parts = {},
          }
          series[i] = slot
        end
        slot.total += bucket.total
        slot.input += bucket.input
        slot.output += bucket.output
        slot.parts[provider.id] = (slot.parts[provider.id] or 0) + bucket.total
      end
      for _, entry in report[range.models] do
        local key = `{provider.id}/{entry.name}`
        local found = models[key]
        if found == nil then
          found = { provider = provider, name = entry.name, totals = blank() }
          models[key] = found
        end
        add(found.totals, entry)
      end
    end
    if sum.total > 0 or sum.messages > 0 then
      add(total, sum)
      table.insert(rows, { provider = provider, totals = sum })
    end
  end
  table.sort(rows, function(a, b)
    return a.totals.total > b.totals.total
  end)
  local modelList = {}
  for _, entry in models do
    table.insert(modelList, entry)
  end
  table.sort(modelList, function(a, b)
    if a.totals.total ~= b.totals.total then
      return a.totals.total > b.totals.total
    end
    return a.name < b.name
  end)
  return { total = total, providers = rows, series = series, models = modelList, range = range }
end

local function percent(part: number, whole: number): string
  if whole <= 0 or part <= 0 then
    return "0%"
  end
  local value = part / whole * 100
  if value < 0.1 then
    return "<0.1%"
  elseif value < 10 then
    return string.format("%.1f%%", value)
  end
  return string.format("%d%%", math.floor(value + 0.5))
end

local function title(text: string)
  return cards.caption(text, "on_surface", { fontWeight = "semibold", maxLines = 1 })
end

-- Big total and the range switch.
local function header(data, options)
  local buttons = {}
  for _, key in M.RANGE_KEYS do
    buttons[#buttons + 1] = ui.button({
      key = `range-{key}`,
      text = noctalia.tr(RANGES[key].label),
      variant = if options.overviewRange == key then "primary" else "ghost",
      controlSize = "sm",
      onClick = function()
        options.onOverviewRange(key)
      end,
    })
  end
  return ui.row({ align = "center", gap = 8 }, {
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = analytics.compact(data.total.total), fontSize = 26, fontWeight = "bold", color = "on_surface" }),
      cards.caption(noctalia.tr("overview.responses_count", { n = analytics.compact(data.total.messages) })),
    }),
    ui.row({ align = "center", gap = 2 }, buttons),
  })
end

-- One row per provider: its logo, share of all tokens and total.
local function providerRows(data)
  local rows = {}
  for _, row in data.providers do
    local provider = row.provider
    local share = if data.total.total > 0 then row.totals.total / data.total.total else 0
    table.insert(rows, ui.column({ key = provider.id, gap = 4 }, {
      ui.row({ align = "center", gap = 8 }, {
        cards.logo(provider, 16),
        ui.column({ gap = 1, flexGrow = 1 }, {
          ui.label({ text = provider.name, fontSize = 13, fontWeight = "semibold", color = "on_surface", maxLines = 1 }),
          cards.caption(noctalia.tr("overview.share_of", { percent = percent(row.totals.total, data.total.total) }), nil, { maxLines = 1 }),
        }),
        ui.label({ text = analytics.compact(row.totals.total), fontSize = 14, fontWeight = "semibold", color = "on_surface" }),
      }),
      ui.progress({ progress = share, height = 3, radius = 2, fill = provider.brand.tint, track = "on_surface/0.08" }),
    }))
  end
  return ui.column({ gap = 10 }, rows)
end

-- Bars stacked by provider, oldest first; the last one is the current hour or day.
local function chart(data)
  local peak = 0
  for _, slot in data.series do
    peak = math.max(peak, slot.total)
  end
  local count = #data.series
  local barWidth = if count > 12 then 8 else 18
  local columns = {}
  for i, slot in data.series do
    local segments = {}
    for _, row in data.providers do
      local part = slot.parts[row.provider.id] or 0
      if part > 0 and peak > 0 then
        table.insert(segments, ui.box({
          width = barWidth,
          height = math.max(2, math.floor(part / peak * CHART_HEIGHT + 0.5)),
          radius = 2,
          fill = row.provider.brand.tint,
          tooltip = `{row.provider.name}: {analytics.compact(part)}`,
        }))
      end
    end
    if #segments == 0 then
      table.insert(segments, ui.box({ width = barWidth, height = 2, radius = 1, fill = "on_surface/0.10" }))
    end
    -- Per-day names fit under their bars; 24 hours get one axis line instead.
    local children = { ui.column({ gap = 1, align = "center", justify = "end" }, segments) }
    if count <= 12 then
      table.insert(children, cards.caption(slot.label, nil, { fontSize = 10, maxLines = 1 }))
    end
    table.insert(columns, ui.column({
      key = `{slot.date or slot.label}-{i}`,
      flexGrow = 1,
      align = "center",
      justify = "end",
      gap = 3,
      height = CHART_HEIGHT + (if count <= 12 then 18 else 0),
    }, children))
  end
  local body = {
    title(noctalia.tr(data.range.chart)),
    ui.row({ gap = if count > 12 then 2 else 4, align = "end" }, columns),
  }
  if count > 12 then
    -- Start, middle and end of the day: "14:00   02:00   now".
    local function at(i: number): string
      return data.series[i].axis
    end
    table.insert(body, ui.row({ align = "center" }, {
      cards.caption(at(1), nil, { fontSize = 10, flexGrow = 1, maxLines = 1 }),
      cards.caption(at(math.ceil(count / 2)), nil, { fontSize = 10, flexGrow = 1, textAlign = "center", maxLines = 1 }),
      cards.caption(at(count), nil, { fontSize = 10, flexGrow = 1, textAlign = "right", maxLines = 1 }),
    }))
  end
  return ui.column({ gap = 8 }, body)
end

local function cell(label: string, value: string)
  return ui.column({ gap = 2, flexGrow = 1 }, {
    cards.caption(label, nil, { maxLines = 1 }),
    ui.label({ text = value, fontSize = 14, fontWeight = "semibold", color = "on_surface", maxLines = 1 }),
  })
end

-- Total, In, Out and responses, then In against Out as one bar.
local function totals(data)
  local sum = data.total
  local inShare = if sum.total > 0 then sum.input / sum.total else 0
  return ui.column({ gap = 8 }, {
    title(noctalia.tr("overview.totals")),
    ui.row({ gap = 8 }, {
      cell(noctalia.tr("overview.total"), analytics.compact(sum.total)),
      cell(noctalia.tr("analytics.in"), analytics.compact(sum.input)),
      cell(noctalia.tr("analytics.out"), analytics.compact(sum.output)),
      cell(noctalia.tr("overview.responses"), analytics.compact(sum.messages)),
    }),
    ui.progress({ progress = inShare, height = 4, radius = 2, fill = "primary", track = "primary/0.3" }),
    ui.row({ gap = 12 }, {
      cards.caption(`{noctalia.tr("analytics.in")} {percent(sum.input, sum.total)}`, nil, { flexGrow = 1 }),
      cards.caption(`{noctalia.tr("analytics.out")} {percent(sum.output, sum.total)}`, nil, { textAlign = "right" }),
    }),
  })
end

local function modelRows(data)
  local rows = {
    ui.row({ align = "center", gap = 8 }, {
      cards.caption(noctalia.tr("overview.models"), "on_surface", { flexGrow = 1, fontWeight = "semibold", maxLines = 1 }),
      cards.caption(noctalia.tr("overview.share"), nil, { width = COLUMN, textAlign = "right", fontWeight = "semibold" }),
      cards.caption(noctalia.tr("overview.tokens"), nil, { width = COLUMN, textAlign = "right", fontWeight = "semibold" }),
    }),
    ui.separator({ color = "outline/0.2" }),
  }
  for i, entry in data.models do
    if i > MODEL_ROWS then
      break
    end
    local share = if data.total.total > 0 then entry.totals.total / data.total.total else 0
    table.insert(rows, ui.column({ key = `{entry.provider.id}/{entry.name}`, gap = 4, tooltip = noctalia.tr("analytics.in_out", {
      input = analytics.compact(entry.totals.input),
      output = analytics.compact(entry.totals.output),
    }) }, {
      ui.row({ align = "center", gap = 8 }, {
        cards.logo(entry.provider, 12),
        ui.label({ text = analytics.modelName(entry.name), fontSize = 12, color = "on_surface", flexGrow = 1, maxLines = 1 }),
        ui.label({ text = percent(entry.totals.total, data.total.total), fontSize = 12, color = "on_surface_variant", width = COLUMN, textAlign = "right", maxLines = 1 }),
        ui.label({ text = analytics.compact(entry.totals.total), fontSize = 12, color = "on_surface", width = COLUMN, textAlign = "right", maxLines = 1 }),
      }),
      ui.progress({ progress = share, height = 3, radius = 2, fill = entry.provider.brand.tint, track = "on_surface/0.08" }),
    }))
  end
  return ui.column({ gap = 6 }, rows)
end

-- Whether any provider has token counts to show (decides if the tab exists).
function M.available(providers): boolean
  for _, provider in providers do
    if #reportsOf(provider) > 0 then
      return true
    end
  end
  return false
end

-- The tab's content, as the list of nodes the panel scrolls.
function M.view(providers, options): { any }
  local data = M.collect(providers, options.overviewRange or "24h")
  local nodes = { header(data, options) }
  if data.total.total == 0 and data.total.messages == 0 then
    table.insert(nodes, cards.caption(noctalia.tr("overview.none"), nil, { maxLines = 3 }))
    return nodes
  end
  table.insert(nodes, providerRows(data))
  table.insert(nodes, chart(data))
  table.insert(nodes, totals(data))
  table.insert(nodes, modelRows(data))
  table.insert(nodes, cards.caption(noctalia.tr("analytics.footnote"), "on_surface_variant/0.8", { fontSize = 10, maxLines = 3 }))
  return { ui.column({ gap = 20, padding = 16, radius = 14, fill = "surface_variant/0.45" }, nodes) }
end

return M
