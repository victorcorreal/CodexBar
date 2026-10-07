# Claude Desktop Accounts

The Claude menu includes **Claude Desktop: email** and a submenu for switching the Mac app's account.
This is separate from Claude Code CLI account switching and its usage cards.
The existing **Hide Personal Information** preference also hides these email addresses.

The local custom menu bar uses its own two-column gauge icon and shows **Cdx** (Codex) and
**Cl** (the running Claude Desktop account) together. Claude shows the current five-hour session
limit, following the existing used/remaining preference. It refreshes about once a minute and
detects profile, account and organization changes about every five seconds. A changed account
clears the previous percentage while its new usage is fetched. Closed, ambiguous, expired or
unreadable Desktop sessions show **—**; they never borrow the CLI account's usage.

The Desktop submenu also shows the current session percentage. When a read fails, it displays
the error and offers **Verify Account Email and Usage…**. The custom bar is enabled for this
local installation with the `customDesktopMenuBarEnabled` preference; the existing layouts remain
available when that preference is disabled.

- **Existing Claude** opens your original Claude environment.
- **Add Claude Desktop Account…** creates an empty profile and opens Claude for sign-in.
- Each profile has separate Desktop and Code configuration directories. Sign in once per profile.
- Selecting a profile asks Claude to quit normally before reopening it. Finish active Code work first.
  CodexBar waits up to about 30 seconds and checks that Claude's main process has exited.
  If Claude does not quit, CodexBar reports an error and does not force it to close.
  The new profile stays saved: once Claude closes, select that profile again rather than adding it twice.
- Conversations belong to their profile. Switching accounts does not transfer conversations.
- Opening Claude from the Dock normally opens the original environment. CodexBar detects the running
  environment rather than treating the last selected profile as active.

CodexBar verifies the Desktop account email using its current access token and Anthropic's profile
endpoint, then reads the OAuth usage endpoint with that same token. Both the returned account and
organization must match Desktop's current context. It never uses Codex identity,
refreshes Desktop tokens, or modifies Claude's original credentials. Background verification cannot
show Keychain prompts. The explicit **Verify Account…** action requests access to **Claude Safe Storage**
if needed. An expired token must be renewed by opening Claude itself.

Profiles live locally under `~/Library/Application Support/CodexBar/ClaudeDesktopProfiles/`.
They contain login data and must not be committed or synced as source code.

The isolation mechanism uses Claude's Electron `--user-data-dir` argument and `CLAUDE_CONFIG_DIR`.
These are not a public Desktop account-management API. Claude updates may require adjustments.

The profile isolation pattern is also used by
[Claude Desktop Switcher](https://github.com/matsumotory/claude-desktop-switcher).
Desktop cache decryption and ownership handling are adapted from OpenUsage; its MIT notice ships
in the app's resources.

For this local fork, run `./script/build_and_run.sh`. It packages a development build with the
installed app's bundle identifier and restarts CodexBar. The version stays at 0.67.0. Adhoc signing
disables the official update feed so automatic updates cannot replace the custom feature.
