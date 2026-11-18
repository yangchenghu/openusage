# Privacy & Usage Data

OpenUsage sends no analytics, usage pings, or crash reports. Nothing about how you use the app leaves
your Mac except the provider and price-list requests described below.

## Credentials stored on this Mac

OpenUsage primarily reads credentials that provider tools already keep on your Mac. When it writes a
user-supplied API key or saves a refreshed credential, the file is replaced atomically and restricted to
your macOS account (owner read and write only). Antigravity's short-lived refreshed-token cache is tied
to the current Keychain login using a one-way fingerprint; the refresh credential itself is not copied.
The cache is never used after logout, an account change, or while Keychain access is unavailable.

Claude, Codex, and Grok can also be signed in inside OpenUsage (**OpenUsage Sign-In** in their
Customize detail), used only when the tool's own login on this Mac is missing or no longer works.
Those sign-ins use each provider's own browser or device sign-in and never write the provider tool's
login. Signing out deletes OpenUsage's copy. The one-shot `openusage` command may ask once for
Keychain access to read OpenUsage's sign-ins.

Cursor is authorized using login beside Cursor in Customize (its status popover's **Copy Link** opens the sign-in in another browser). The browser sign-in uses PKCE.

All of OpenUsage's own sign-ins (Claude, Codex, Grok, Cursor) live in one OpenUsage Keychain item,
separate for development and release builds, read once per launch. Older builds kept one item per
provider; the first launch moves them into the single item and deletes the old ones. It does not write to the Cursor app's credentials. Choosing logout deletes
OpenUsage's item and disables Cursor without falling back to the Cursor app's login.

**Sign-In Transfer** (Settings) exports these OpenUsage sign-ins (never a tool's own login) to a file
you save, encrypted with AES-GCM under a key derived from a password you choose; nothing is uploaded.
Importing the file on another Mac saves the sign-ins into that Mac's OpenUsage Keychain item. Because
providers renew sign-ins with single-use tokens, using the same sign-in on two Macs at once can sign
one of them out.

Claude Desktop access is strictly read-only. OpenUsage may ask macOS for permission to use the
`Claude Safe Storage` Keychain item so it can decrypt Desktop's current access token. It never uses
Desktop's rotating refresh token and never modifies Desktop's config, cookies, or Keychain data.

## Other network requests

Besides the provider API calls the vendor's own tools would make, OpenUsage fetches public [model price lists](pricing.md) about once an hour (from `raw.githubusercontent.com`, `models.dev`, and this project's GitHub Pages). These are plain downloads of public data — they carry no usage, log, or account information. The spend tiles are computed from local CLI logs entirely on your Mac; no log data ever leaves it.

To avoid re-reading unchanged Claude, Codex, and pi logs after every relaunch, OpenUsage keeps their
parsed usage events in `~/Library/Application Support/OpenUsage/log-scan-cache/`. These records contain
the usage metadata needed for local totals, including any per-event cost already recorded by a provider,
but not raw JSONL lines or conversation text. They are private to your macOS account and are never sent
anywhere. Old source-file records are dropped as the scan window advances, and
identity caches that have not been used for 35 days are removed. OpenUsage's pricing engine runs after
the cache is read, so its computed aggregates and totals are not persisted in this cache.
