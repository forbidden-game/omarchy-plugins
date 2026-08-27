# Agents

One bar icon and one panel for every AI coding subscription on the machine.
The panel is strictly a display: it watches the usage records that
`omarchy-agent-usage-update` writes to `~/.local/state/omarchy/agents/usage/`
and draws whatever appears there. `Panel.qml` owns the bar button and the
popup; `Main.qml` discovers and watches the records (and handles the optional
cross-device aggregation); `Agent.qml` is the per-record file watcher.

## Panel

- **Hero** — the mark, the tool, and the plan it runs on ("Max 20x", "Pro").
  Auth and endpoint problems replace the plan line and repeat in a card.
- **Subscription switch** — one chip per enabled agent (`h`/`l` or click).
  It appears only when more than one agent is enabled.
- **Limits** — the percentage of each allowance used, a matching meter, and
  the time until the session or weekly window resets.
- **Balance** — prepaid agents report a credit ledger instead of limits:
  remaining credit, a fuel-gauge meter that drains toward empty, and
  funded-versus-spent detail.
- **All agents banner** — the top line shows today's unified machine usage:
  rated spend plus the exact token and prompt counts behind it.
- **Tokens by day** — one row per day for the last week across all agents:
  day, bar, tokens, with today bolded at the bottom. Hover today for its
  prompt and session count.
- **Tokens & cost by model** — one flat ranking across every agent, heaviest
  token consumer first, each row tagged with the subscription that ran it.
  Hover a row for the input / output / cache split and the rates applied.
  Rates live in `js/Pricing.js` with their official sources and the date
  they were checked. Tokens from a legacy record without that split remain
  in the total as `unrated`; they never receive an invented fallback price.

A subscription appears only when it is enabled in settings and has actually
recorded usage — on this machine or on a synced one. With one such agent
there is no switch row at all; with none, the module leaves the bar entirely
rather than sitting there with nothing to say. A CLI installed mid-session
shows up at the next refresh, so nothing polls the disk waiting for it.

That self-hiding is why the widget ships in the default bar layout: a machine
that has never run an AI coding agent draws nothing, and the icon arrives on
its own the first time a scan finds usage. Drop it with
`omarchy plugin disable omarchy.agents`.

## Data

Each agent is one JSON record in `~/.local/state/omarchy/agents/usage/`,
written by `omarchy-agent-usage-update`. That command runs one
`omarchy-agent-usage-<agent>` collector per agent; the widget invokes it
on its refresh timer and whenever you ask for a refresh, and picks up any
record that lands in the directory regardless of who wrote it.

Adding an agent therefore never touches this plugin: ship a collector that
prints the record contract (see the `claude` and `codex` collectors in
`bin/`), and the panel gains a tab. An `assets/<id>.svg` mark is optional —
with an `assets/<id>-light.svg` twin if the mark needs a dark variant for
light surfaces — and the bar glyph stands in when there is none.

Prompts are counted as agent turns, not model calls: one message that fans
out into a dozen tool-loop calls is still one prompt. The shared machine
collector dedupes `turnId` from ZCode's rollout logs and counts one
`turn_context` per task in native Codex session files. Usage events from
sources without turn markers contribute tokens only, never prompts.

Transcript usage has one owner: the Codex record is the unified machine
dataset for Codex, ZCode, pi/omp, opencode, and agy sessions, except rows
already owned by Claude or Fireworks. Antigravity contributes only its
subscription/account state. This separation is what keeps provider tabs from
multiplying the same local tokens and price.

| Collector | Limits | Local stats |
|---|---|---|
| `claude` | Anthropic's OAuth usage endpoint (5-hour session + 7-day weekly) | `~/.claude/projects` transcripts, opencode sessions on an Anthropic provider, plus `stats-cache.json` and `history.jsonl` as fallback |
| `codex` | The Codex app-server RPC | unified machine usage from native Codex, ZCode, pi/omp, opencode, and Antigravity (agy) sessions |
| `antigravity` | Google Cloud Code API (5-hour session + 7-day weekly per model group) & standalone multi-account switching with OAuth | — (subscription state only; usage is already in the unified machine dataset) |
| `fireworks` | Estimated prepaid balance: configured funding minus rated account costs | Fireworks billing API, grouped by day and model for the last 30 days |

### Antigravity streaming proxy

The Antigravity tab can run a loopback-only OpenAI Responses proxy for `pi`
and `omp`. The helper installs an enabled user-level systemd service,
generates a random local API key, and adds the `antigravity-proxy` provider to
both clients without changing their default models.

Credentials have one source of truth:
`~/.config/omarchy/agents/antigravity/auth/`. CLIProxyAPI and the Agent Panel
auth controller are the only runtime writers for access-token refreshes;
consumers such as Omarvoice never read or rewrite the credential directly.
Account files under `accounts/` contain display and quota metadata only, so
restarting a consumer cannot replace a new token with an older copy. A
five-minute systemd watchdog restarts the proxy once for a new authentication
failure and notifies the desktop if the same failure persists.

The configured models use the clients' `openai-responses` implementation, so
reasoning summaries, interactive responses, and tool calls use typed streaming
events over SSE:

```bash
pi --model antigravity-proxy/gemini-3.7-flash-high
omp --model antigravity-proxy/gemini-3.7-flash-high
```

The panel starts and stops `omarchy-antigravity-proxy.service` and can copy
either launch command. The service starts with the user session; stopping it
from the panel keeps it stopped until the next manual start or login. Runtime
configuration stays under `~/.config/omarchy/agents/antigravity/proxy/`; no
secret is stored in this repository.

### Omarvoice authentication

Omarvoice reuses the active Antigravity account and long-lived OAuth flow from
this plugin. `voice-auth-status` exposes readiness metadata only;
`voice-auth-sync` refreshes the canonical credential only when its access
token is near expiry, then writes Antigravity's native token shape directly to
the desktop keyring. No token is printed or passed through QML.

On a new machine, `oauth-client-bootstrap` extracts the supported OAuth client
shipped in Antigravity's `language_server`. It chooses the client ID and secret
only when their SHA-256 fingerprints match the compatibility table, writes
`oauth.json` with mode `0600`, and never prints either value. `oauth-start`
then opens the default browser, waits for the loopback callback, and persists
that machine's refresh token. Run the repository's `setup-omarvoice.sh` to
orchestrate this complete path.

Antigravity 2.11 dictation requires the additional
`https://www.googleapis.com/auth/aicode` scope. The OAuth flow requests it for
new authorizations. Existing accounts must explicitly authorize once more;
the old refresh token cannot gain a new scope silently.

Claude limits need a signed-in CLI; without credentials the panel says so and
falls back to local stats only. A non-default Claude directory is honored via
`CLAUDE_CONFIG_DIR`, Codex via `CODEX_HOME`. Fireworks reads
`FIREWORKS_API_KEY` and `FIREWORKS_ACCOUNT_ID` first, then
`~/.fireworks/auth.ini` (which `firectl set-api-key` creates), then the key
opencode stores in `~/.local/share/opencode/auth.json` when Fireworks is
signed in there.

### Fireworks balance

The collector first asks the account's `:getBalance` endpoint for the real
prepaid ledger. That endpoint exists but is permission-gated, and as of
August 2026 no console-issued API key passes it — Fireworks appears to
reserve it for the dashboard session. The probe stays because it is cheap
and the live figure lights up automatically if Fireworks ever opens it to
keys. Until then the collector falls back to estimating the balance from
configuration in `~/.config/omarchy/agents/fireworks.json`:

```json
{
  "accountId": "",
  "fundedAmount": 20,
  "fundedAt": "2026-07-01"
}
```

Set `fundedAmount` to the credits purchased and optionally `fundedAt` to the
purchase date; with no date, the collector uses the account creation time. It
subtracts rated account costs and the panel labels the result as estimated.
For a later top-up, increase `fundedAmount` by the new credit while keeping
the original `fundedAt`, so both the funding and spend still cover the same
period. `accountId` only matters when one API key can access several
accounts. Without a configured `fundedAmount` the tab still shows token
usage, just no balance. With a live ledger, `fundedAmount` is optional and
only adds the meter and the spent-of-funded line under the real figure.

## Interactions

- Bar icon: left = panel, right = launch agent, middle = next subscription.
- Panel: `h`/`l` switch subscription, `j`/`k` scroll, `r` or Enter refresh,
  Tab moves to the neighboring bar panel, Esc closes.
- IPC: `omarchy-shell omarchy.agents <open|close|toggle|refresh|next>`.

## Settings

Settings live in the widget's entry in `~/.config/omarchy/shell.json`. The
top-level keys can be set with
`omarchy bar set omarchy.agents <key> <value>`:

| Key | Default | What it does |
|---|---|---|
| `refreshIntervalSec` | `900` | How often the usage records regenerate |
| `syncMode` | `"Off"` | `"On"` writes this machine's snapshot and merges the others |
| `syncDir` | `""` | A folder synced by Syncthing, Dropbox, rsync, … |
| `syncFileName` | `<hostname>.json` | This machine's snapshot file |
| `syncDeviceId` | hostname | Stable device name inside the snapshot |

Numbers need `--json`, or they land in `shell.json` as strings:

```bash
omarchy bar set omarchy.agents refreshIntervalSec 300 --json
omarchy bar set omarchy.agents syncDir '~/Sync/agent-usage'
```

Per-agent enablement is nested, and `set` writes its key literally rather
than walking a dotted path — so pass the whole `providers` object as JSON (or
edit `shell.json` directly):

```bash
omarchy bar set omarchy.agents providers '{
  "claude": { "enabled": true },
  "codex": { "enabled": false },
  "fireworks": { "enabled": true }
}' --json
```

`enabled` defaults to `true` for every discovered agent; set it to `false` to
hide a subscription that is installed. Disabled agents are also skipped when
the records regenerate.

With `syncMode` on, every `*.json` snapshot in `syncDir` is merged, so today,
the last 7 days, and the all-time totals cover every machine you code on —
active days are unioned by date rather than summed. Rate limits stay
per-account and are never merged. A record may declare `"scope": "account"`
when its stats are account-global rather than machine-local (Fireworks'
billing API); those merge by taking the widest value instead of summing, so
the same account synced from two machines is not counted twice.

One caveat on "all-time": the unified collector only reads native Codex and
agy session files touched in the last 30 days; ZCode totals cover the rollout
logs still on disk. Fireworks requests the last 30 days from its billing API.
Claude's totals cover every transcript still on disk.
