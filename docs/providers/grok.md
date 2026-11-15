# Grok

Tracks Grok Build credit usage using the login from the Grok CLI.

## What it tracks

| Metric | Meaning |
|---|---|
| Weekly | The shared weekly pool's usage percent (the limit Grok's unified billing enforces), with the weekly reset countdown |
| Extra Usage | Pay-as-you-go cap in dollars as a status (e.g. `$25.00 cap` or `Disabled`) |
| Today / Yesterday / Last 30 Days | Local cost and tokens from completed Grok CLI sessions |

When Grok reports your subscription tier, OpenUsage shows it beside the provider name.

The weekly shared pool is the limit Grok enforces for unified-billing accounts (the old monthly credits meter is legacy and no longer shown). Accounts that haven't been migrated to unified billing have no weekly pool, so the Weekly tile reads "No data" there.

## Signing in inside OpenUsage

Grok is turned on by signing in inside OpenUsage, like Cursor: click **login** beside Grok in
Customize. A device code appears beside the button and xAI's device page opens; enter the code there to approve. **Copy Link** copies the device page's address, so you can approve in any browser, even on another device. A successful sign-in turns Grok on and shows **logout**; logging out turns it off.
While signed out, OpenUsage does not read the provider tool's login on this Mac at all. The tokens
live in OpenUsage's own Keychain item and renew automatically; if the provider refuses a renewal, the
card asks you to log in again. OpenUsage never writes to `~/.grok/auth.json`. The **Account** card in the provider's Customize detail shows
which account is signed in.

## Where credentials come from

Sign in once with the Grok CLI (`grok login`); OpenUsage reads the same `~/.grok/auth.json`. Access tokens refresh automatically before expiry, and rotated tokens are written back to the file.

## The spend tiles

Today / Yesterday / Last 30 Days are computed **locally** from completed Grok CLI sessions under `~/.grok/sessions/` (or `$GROK_HOME/sessions/`). This includes subagent, resumed, and forked sessions: their work is not necessarily included in the parent session's usage. Copies of the same completed event are counted once per model across session logs. OpenUsage uses the cost Grok recorded for each completed turn when available; older turns without a recorded cost are estimated using the shared [model pricing](../pricing.md). Days follow your Mac's local time zone, and each period shows cost and tokens together (`$4.08 · 1.2M tokens`). These amounts are separate from the credits reported by Grok's billing API, and no session data leaves your Mac. A period with no completed usage reads "No data" rather than `$0.00 · 0 tokens`.

## Troubleshooting

- **"Session expired" / auth errors** — run `grok login` again, then refresh.
- **Weekly shows "No data"** — your account still reports a monthly (non-weekly) period, meaning it hasn't been migrated to Grok's unified weekly billing yet.
- **Weekly and Extra Usage stay blank on a team/business login** — Grok's credits endpoint only resolves a personal team (`HTTP 412` / "No personal team"). That's an account shape, not a failed login. OpenUsage keeps the Grok card up, shows the plan name when settings returns it, and still fills Today / Yesterday / Last 30 Days from local session logs. A header note explains the blank quota rows.
- **Spend tiles show "No data"** — they need completed Grok CLI turns under `~/.grok/sessions/`; a turn that is still running has not been recorded yet. Finish a Grok CLI session, then refresh.

## Under the hood

`GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` for the weekly pool and pay-as-you-go cap — the exact call the Grok CLI itself makes — and `…/v1/settings` for the plan name; token refresh via `auth.x.ai`. A 401/403 triggers one token refresh and retry.
