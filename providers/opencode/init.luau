--!nonstrict
-- opencode (https://opencode.ai). It has no plan limits of its own to report,
-- so this provider shows token usage only: the card carries the analytics block
-- (lib/analytics.luau), built from the sqlite database opencode keeps on disk.
--
-- No network, no process: "fetching" only checks that the database exists.

local model = require("../../lib/model.luau")
local provider = require("../../lib/provider.luau")

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

return provider.define({
  id = "opencode",
  name = "opencode",
  brand = {
    logo = "providers/opencode/logo.svg",
    tint = "#8a8f98",
    glyph = "terminal-2",
  },

  analytics = {
    source = "opencode",
    folders = function(ctx)
      return { dataFolder(ctx) }
    end,
  },

  isConfigured = function(ctx)
    return ctx.fileExists(database(ctx))
  end,

  signInHint = function(ctx)
    return ctx.tr("providers.opencode.hint")
  end,

  -- Nothing to ask anyone: an account with no windows, only its token counts.
  fetch = function(ctx, done)
    done(model.snapshot({ windows = {}, notes = {}, fetchedAt = ctx.now() }), nil)
  end,
})
