# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Headroom is a Noctalia shell plugin (Luau, `plugin_api = 32`) that shows how much of a Claude / Antigravity plan's limits is left, in a bar widget and a panel. This is a personal fork (plugin id `okarin/headroom`) of the community-plugins version. `README.md` documents user-facing behavior, settings and the exact network calls and processes; `CONTRIBUTING.md` has the full file map and the provider walkthrough.

## Commands

```sh
scripts/test.sh                 # whole suite; downloads the Luau CLI into .tools/ on first run (or set LUAU=/path/to/luau)
noctalia plugins lint .         # manifest/plugin lint
scripts/stage.sh <checkout>     # copy only the shipped files into a community-plugins checkout
```

- There is no single-test filter. `tests/run.luau` requires each `tests/*_spec.luau`; to iterate on one, temporarily comment out the other `require`s there.
- `scripts/test.sh` first embeds every `.luau`, SVG, fixture, `translations/en.json` and `plugin.toml` into `tests/_generated/sources.luau` (gitignored, never edit), because the Luau CLI has no file I/O. `tests/support/loader.luau` loads them in a sandbox with a fake `noctalia` host (`tests/support/host.luau`) and Noctalia's `require("./x.luau")` semantics. New source files are picked up automatically; new fixtures must live in `tests/fixtures/`.
- The test script also fails when provider registration drifts: a provider in `providers/registry.luau` without a `provider_<id>` setting in `plugin.toml`, a setting without a provider, or a translation key that is used but missing / defined but unused.
- Live dev: symlink the repo into `~/.local/share/noctalia/plugins/headroom` and `noctalia msg plugins enable okarin/headroom`. `.luau` edits hot-reload; `plugin.toml` and `translations/` are only read on enable, so after changing them run `noctalia msg plugins disable okarin/headroom && noctalia msg plugins enable okarin/headroom`. Logs: `~/.cache/noctalia/noctalia.log` (`grep headroom`).

## Architecture

One-way data flow: `provider adapter.fetch(ctx)` → `service.luau` → `noctalia.state("report")` → `bar.luau` / `panel.luau`. The surfaces write user actions (refresh, add/sign in/remove account) back through `noctalia.state("command")`, which only the service executes. `service.luau` is the **only** entry that fetches or runs processes; bar and panel are presentation only.

Key constraint: adapters (`providers/<id>/init.luau`) never touch the `noctalia` global. Everything they may do (read a file, HTTP JSON, run a command, translate) comes through the `Context` built in `lib/context.luau` against the contract in `lib/provider.luau`. Preserve this when editing adapters — it keeps side effects reviewable and lets `tests/providers_spec.luau` run them against recorded fixtures. Adapters return the normalized `model.Snapshot` / `model.err(code)` from `lib/model.luau`; the rest of the code (forecasts in `lib/pace.luau`, notifications in `lib/notify.luau`, scheduling/backoff in `lib/scheduler.luau`, rendering in `lib/view.luau` + `ui/cards.luau`) only knows that model.

Adding a provider touches: `providers/<id>/init.luau` + `logo.svg`, one line in `providers/registry.luau`, a `provider_<id>` select in `plugin.toml`, `settings.provider_<id>.label` and `providers.<id>.hint` in `translations/en.json`, a fixture + cases in `tests/providers_spec.luau`, and the README's Requirements/Notes. The bar and panel need no changes.

Per-account support (Claude): an adapter's `accounts` spec lets `lib/accounts.luau` enumerate config folders (`CLAUDE_CONFIG_DIR` and `~/.claude-*` siblings, plus accounts added from the panel); the adapter then runs once per account with `ctx.home` set, and any command it spawns must be wrapped in `ctx.inHome(argv)`.

Token analytics (`lib/analytics.luau`, `lib/analytics_script.luau`) shell out to `python3` out-of-process to sum tokens from the CLIs' local transcripts/databases; the feature is skipped when `python3` is missing or the `analytics` setting is off.

## Rules that are easy to violate

- Credentials are read-only: never refresh or write a vendor token (refresh tokens rotate and would sign the CLI out). On expiry, report `expired` or renew via the vendor CLI through `lib/renew.luau`.
- Only call the vendor's own usage endpoint; run commands only via `ctx.run` as an argument list, never a shell string, and document each command in the README's *Notes*.
- Keep response bodies, tokens and emails out of errors and logs; treat every response field as optional and return a `parse` error instead of throwing.
- User-visible strings go through `translations/en.json` keys; a key used in code but absent (or defined but unused) fails the test script.
- `noctalia.d.luau` (editor typings from official-plugins), `.tools/` and `tests/_generated/` are gitignored.
