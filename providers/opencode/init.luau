--!nonstrict
-- opencode (https://opencode.ai). Two things come from it:
--
--   * Token usage, for every user: the card carries the analytics block
--     (lib/analytics.luau), built from the sqlite database opencode keeps on disk.
--   * The OpenCode Go plan's limits (5-hour, weekly, monthly spend), for users
--     signed in to an OpenCode account: GET https://opencode.ai/console/api/go/status,
--     the same endpoint opencode's own console uses, with the access token opencode
--     already holds. The token is read from opencode's database by a short
--     read-only `python3 -I -c` run (Luau has no sqlite) and is never refreshed,
--     written or logged. Without it, or without a Go plan, the card shows tokens only.

local model = require("../../lib/model.luau")
local provider = require("../../lib/provider.luau")
local time = require("../../lib/time.luau")

local E = model.ErrorCode

local STATUS_URL = "https://opencode.ai/console/api/go/status"
local DAY = 86400
local MONTH_SECONDS = 30 * DAY
local TOKEN_TTL = 600 -- how long a token read from the database is reused

-- Prints {"access", "expires" (ms), "email"} for the active OpenCode login, or {}.
local TOKEN_SCRIPT = [[
import sys, os, json, sqlite3
try:
    db = sqlite3.connect("file:" + os.path.join(os.path.expanduser(sys.argv[1]), "opencode.db") + "?mode=ro", uri=True, timeout=2)
    row = db.execute("select value from credential where integration_id = 'opencode' order by active desc, time_updated desc limit 1").fetchone()
    cred = json.loads(row[0]) if row else {}
    meta = cred.get("metadata") or {}
    out = {"access": cred.get("access"), "expires": cred.get("expires"), "email": meta.get("email")}
except Exception:
    out = {}
print(json.dumps(out))
]]

local tokenCache: { access: string?, expires: number?, email: string?, at: number } = { at = -math.huge }

local DEFAULT_DATA_HOME = "~/.local/share"

-- opencode's data folder: $XDG_DATA_HOME/opencode, else ~/.local/share/opencode.
local function dataFolder(ctx): string
  local home = ctx.env("XDG_DATA_HOME")
  if home == nil or home == "" then
    home = DEFAULT_DATA_HOME
  end
  return `{home}/opencode`
end

local function database(ctx): string
  return ctx.expandPath(`{dataFolder(ctx)}/opencode.db`)
end

-- The access token from opencode's database, reused for TOKEN_TTL. done(nil)
-- without python3, a database, or a login.
local function readToken(ctx, done)
  if tokenCache.access and ctx.now() - tokenCache.at < TOKEN_TTL then
    done(tokenCache)
    return
  end
  if not ctx.which("python3") then
    done(nil)
    return
  end
  ctx.run({ "python3", "-I", "-c", TOKEN_SCRIPT, dataFolder(ctx) }, 10000, function(result)
    local ok, data = pcall(ctx.decodeJson, if result and result.exitCode == 0 then result.stdout else "")
    if not ok or type(data) ~= "table" or type(data.access) ~= "string" or data.access == "" then
      tokenCache = { at = -math.huge }
      done(nil)
      return
    end
    tokenCache = {
      access = data.access,
      expires = tonumber(data.expires),
      email = if type(data.email) == "string" then data.email else nil,
      at = ctx.now(),
    }
    done(tokenCache)
  end)
end

-- One Go meter -> a window: the percent of its spend limit used.
local function meter(ctx, id: string, kind: string, label: string, raw: any, periodSeconds: number, resetsAt: number?)
  local limit, used = type(raw) == "table" and tonumber(raw.limitMicroCents), type(raw) == "table" and tonumber(raw.usedMicroCents)
  if not limit or not used or limit <= 0 or used < 0 then
    return nil
  end
  local window = model.window({
    id = id,
    kind = kind,
    label = label,
    usedPercent = used / limit * 100,
    resetsAt = resetsAt,
    periodSeconds = periodSeconds,
  })
  return window
end

-- Exposed for tests: the Go status document -> Snapshot, nil when it has no meters.
local function parse(data, ctx): model.Snapshot?
  local access = type(data) == "table" and data.access
  local meters = type(access) == "table" and access.meters
  if type(meters) ~= "table" then
    return nil
  end
  local month = type(meters.month) == "table" and meters.month or {}
  local monthEnd = time.parseIso8601(month.resetsAt or access.endsAt)
  local monthStart = time.parseIso8601(access.startsAt)
  local windows = {}
  for _, def in {
    { "fiveHour", "go-5h", "session", ctx.tr("window.session"), model.SESSION_SECONDS },
    { "week", "go-weekly", "weekly", ctx.tr("window.weekly"), model.WEEK_SECONDS },
    { "month", "go-monthly", "other", ctx.tr("window.monthly"), if monthStart and monthEnd and monthEnd > monthStart then monthEnd - monthStart else MONTH_SECONDS },
  } do
    local raw = meters[def[1]]
    local resets = if def[1] == "month" then monthEnd else time.parseIso8601(type(raw) == "table" and raw.resetsAt or nil)
    local window = meter(ctx, def[2], def[3], def[4], raw, def[5], resets)
    if window then
      table.insert(windows, window)
    end
  end
  if #windows == 0 then
    return nil
  end
  return model.snapshot({ plan = "Go", windows = windows, notes = {}, fetchedAt = ctx.now() })
end

return provider.define({
  id = "opencode",
  name = "opencode",
  brand = {
    logo = "providers/opencode/logo.svg",
    tint = "on_surface",
    glyph = "terminal-2",
  },

  analytics = {
    source = "opencode",
    folders = function(ctx)
      return { dataFolder(ctx) }
    end,
  },

  parse = parse,

  isConfigured = function(ctx)
    return ctx.fileExists(database(ctx))
  end,

  signInHint = function(ctx)
    return ctx.tr("providers.opencode.hint")
  end,

  fetch = function(ctx, done)
    local function tokensOnly()
      done(model.snapshot({ windows = {}, notes = {}, fetchedAt = ctx.now() }), nil)
    end
    readToken(ctx, function(token)
      if token == nil then
        tokensOnly()
      elseif token.expires ~= nil and token.expires / 1000 <= ctx.now() + time.EXPIRY_MARGIN then
        -- opencode renews its own login when it runs; Headroom never does.
        done(nil, model.err(E.Expired))
      else
        ctx.getJson(STATUS_URL, {
          ["Authorization"] = `Bearer {token.access}`,
          ["Accept"] = "application/json",
          ["User-Agent"] = ctx.userAgent,
        }, function(data, err)
          if err then
            -- No Go plan (or an account the endpoint doesn't know): tokens only.
            if err.code == E.Auth or err.code == E.NoPlan then
              tokensOnly()
            else
              done(nil, err)
            end
            return
          end
          local snapshot = parse(data, ctx)
          if snapshot == nil then
            tokensOnly()
            return
          end
          snapshot.email = token.email
          done(snapshot, nil)
        end)
      end
    end)
  end,
})
