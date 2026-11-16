# Which Providers Are On

How OpenUsage decides which providers start on, what happens when an update adds a new provider, and the one rule that governs it all: **your own toggles always win and are never overridden.**

## First install

A fresh install starts with no providers on and opens the menu bar. It does not list sign-ins found on this Mac. Turn providers on in **Customize**.

See [Dashboard § First launch](dashboard.md#first-launch).

## When an update adds a new provider

The same detection runs for providers that arrive later. On the first launch after an update, OpenUsage compares the providers it now ships with the ones this install has seen before. For each brand-new one, it runs the same local-only credential check:

- **Credentials are available locally** → the provider turns on and appears on the dashboard.
- **No credentials are available** → it stays off. You can always turn it on later in **Customize**.

A new account of a provider you already have (say, a second Codex login) follows that provider instead: it turns on with credentials if the provider is on, and stays off if you turned the provider off.

This check happens **once per provider**. After that, the provider is yours to manage: if you turn it off, no update will ever turn it back on, and installing the tool later won't flip it on behind your back either — head to Customize when you want it.

## Your choices always stick

Claude, Codex, Cursor, and Grok each have a **Login Method** in their Customize detail:

- **Local Login** (the default) reads the login the tool already has on this Mac (Claude Code, the
  Codex CLI, the Cursor app, the Grok CLI). The provider keeps its normal on/off toggle and is
  detected like any other provider.
- **OpenUsage Sign-In** uses a sign-in kept by OpenUsage itself. Login/logout replaces the toggle: a
  successful login turns the provider on and refreshes it, logout turns it off, and each launch sets
  it from the saved sign-in. The tool's own login on this Mac is not read, and Reset All never turns
  it on. (With several Claude or Codex cards, only the default card offers this.)

Switching the method drops the cached usage and turns the provider on only if the new method has a
login to use. On the first launch with login methods, a provider that already has an OpenUsage
sign-in keeps using it; the others switch to Local Login. OpenUsage sign-ins can be moved to another
Mac from Settings → Sign-In Transfer.

Everything you set in Customize — providers on or off, metric layout, menu-bar stars — carries across updates untouched. The only thing an update may ever change is turning **on** a provider you have never seen before, and only when you actually have that tool installed.

The one exception is deliberate: the **Reset All Customization** button at the top of the Customize provider list. Because you asked for a clean slate, it re-runs a local credential check and switches the enabled set back to exactly the providers with credentials available on your Mac (Claude/Codex if none are found) — so it can turn a provider off even if you had it on, or back on if you had turned it off. Cursor still requires its OpenUsage authorization. It also asks for confirmation first. See [Dashboard](dashboard.md) for the metric side of that reset.

## How it works (for the curious)

The app persists three small lists in its settings:

- **Enabled providers** — the providers currently on. This is the source of truth the dashboard and menu bar read.
- **Known providers** — every provider this install has ever seen. This is what makes "new in this update" distinguishable from "you turned it off": a provider missing from the enabled list but present in the known list is a deliberate choice, and is left alone. Only providers missing from *both* get the credential check, and each is marked known immediately so the check never repeats.
- Each provider implements a cheap, local-only credential probe (`hasLocalCredentials()`) — the same files, keychain entries, saved keys, and environment variables its normal refresh reads, never the network.

Older installs (from before first-run detection existed) started with every provider on and stored only the ones turned *off*. A one-time settings migration converts them to the lists above with the exact same providers on and off as before — nothing visibly changes on the launch that migrates; those installs simply join the same new-provider detection from then on.
