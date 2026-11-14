# Cursor

Tracks your Cursor plan usage with a browser sign-in or the login from the Cursor app.

## What it tracks

| Metric | Meaning |
|---|---|
| Total Usage | Plan usage for the billing cycle (percent or dollars; included request count vs. cap on request-based Enterprise accounts) |
| Cursor Models | Usage percent for Cursor's own models, including Cursor Grok and Composer |
| Other Models | Usage percent for other models |
| Grok Bot | Grok Bot weekly usage percent and reset countdown; enabled by default |
| Extra Usage | On-demand spend; user-scoped when available, otherwise the team aggregate; shown as a meter when Cursor returns a limit |
| Requests | Optional copy of the included request count vs. cap for custom layouts |
| Credits | Credit balance left from grants and prepaid account balance |

Teams seats with two usable model-pool percentages use those percentages instead of the legacy
included-dollar cap. Total Usage uses Cursor's structured total percentage when supplied; it is
unavailable when Cursor supplies only the two pools. Older team accounts without usable pool data
keep their dollar meter, including accounts that return zero placeholders beside positive spend.
Without a dollar limit or usable model pools, Team/Enterprise accounts use the reported total percentage.

When Cursor reports your plan name, OpenUsage shows it beside the provider name.
Enterprise/team seats sometimes still return `GetPlanInfo.planName = Pro`; OpenUsage prefers the
billing membership from Cursor's local state (`stripeMembershipType`) or `usage-summary` when that
membership is `enterprise` / `team` and GetPlanInfo is missing or still says Pro.

Enterprise/team seats that already return usable model-pool percentages from the primary usage API
may still omit on-demand there. In that case OpenUsage merges Extra Usage from `usage-summary`
without replacing the live pool meters. Personal Pro seats are not probed for that merge.

Grok Bot has its own usage allowance, separate from Cursor's normal billing-cycle meter. Its widget
is enabled by default in Cursor's On Demand section. It uses your existing Cursor login, so signing
into the Grok CLI is not required.

## Where credentials come from

Open **Customize → Cursor → Account → Sign In…** to authorize OpenUsage in your browser, using the
same sign-in flow as main. Finish authorization within five minutes. You can close the menu panel
while waiting; reopen Customize → Cursor to see the result or cancel. After a successful sign-in,
Cursor is enabled and its usage refreshes automatically.

The authorized account takes priority over Cursor's local login. Its credentials are saved in
OpenUsage's own macOS Keychain item, separately for development and release builds. OpenUsage
checks the new account with a usage request before saving it. Its JWT renews up to a week before
expiry; Cursor's new access JWT becomes the next refresh token when no separate one is returned.
If saving a renewal fails, OpenUsage keeps it in memory, shows a warning, and retries saving later.

With no OpenUsage browser account, the original behavior remains: OpenUsage reads Cursor's local
state database and Keychain entries. **Use Cursor App Login** removes only OpenUsage's saved account
and returns to that source. Browser sign-in never modifies Cursor's database or Keychain items.
Changing the selected login clears the previous account's displayed snapshot and history cache.

For browser accounts, billing membership is read from `usage-summary` once an hour; it does not
inherit another account's local `stripeMembershipType`.

When a local session has no separate refresh token, OpenUsage can renew using its access JWT,
as Cursor's browser/CLI login does. A stored refresh token still takes priority. A failed renewal
is logged, and the existing access token is tried before showing a login error.

Extra Usage keeps each budget's spend and remaining allowance together: a personal cap uses personal
spend, and a shared team cap uses team spend. Missing remaining allowance does not imply the cap is
fully spent. Bounded Extra Usage resets with the reported billing cycle.

## Spend history

Today, Yesterday, Last 30 Days, and Usage Trend come from Cursor's usage history—the same data shown on Cursor's Usage page. OpenUsage keeps each day on your Mac, separately for each Cursor account, and re-checks today and yesterday on every refresh. It fills in missing older days in the background within 20 seconds per refresh. A failed or short download never erases stored days. The chart appears once all 30 days are stored; heavy accounts may take a couple of refreshes the first time.

A day with zero events is valid even when Cursor omits the event list. It does not prevent the
30-day history from completing.

The generic request-count fallback fills both Total Usage and the optional Requests widget, and
loads history too. It does not require enabling a hidden widget to see the included allowance.

## Troubleshooting

- **"Not logged in" / token errors** — open Customize → Cursor and choose Sign In… or Sign In Again….
- **Browser sign-in failed** — retry; the previous saved account remains available. A Keychain access
  failure is shown explicitly and does not switch silently to a different local account.
- **Some metrics missing** — Cursor omits fields depending on plan type; missing metrics simply show "No data".
- **Optional lookup failed** — Grok Bot, plan, credit-grant, prepaid-balance, and request-fallback failures stay nonfatal when primary usage is available. OpenUsage records fixed, credential-free reasons in the diagnostic log.

## Under the hood

Connect RPC on `api2.cursor.sh` (dashboard usage and `DashboardService/GetSandUsageStatus` for Grok Bot), combined REST fallback at `cursor.com/api/usage` and `cursor.com/api/usage-summary` for Enterprise/team accounts, Stripe balance at `cursor.com/api/auth/stripe`, and paged usage events at `cursor.com/api/dashboard/get-filtered-usage-events`. The fallback combines the included request allowance with structured percentages and user-scoped on-demand spend; neither REST response is treated as the whole account snapshot by itself. The primary dashboard usage request refreshes the token and retries once after a 401/403; optional endpoint failures stay nonfatal when the other fallback response is usable and are recorded in the diagnostic log. Per-day spend imputation uses usage-event token counts priced through the shared [model pricing](../pricing.md); Cursor-native models (`auto`, `composer-*`, …) come from its supplement layer, which maintainers sync from [Cursor models & pricing](https://cursor.com/docs/models-and-pricing.md).
