# Claude Desktop Accounts

The Claude menu includes **Claude Desktop: email** and a submenu for switching the Mac app's account.
This is separate from Claude Code CLI account switching and usage cards.

- **Existing Claude** opens your original Claude environment.
- **Add Claude Desktop Account…** creates an empty profile and opens Claude for sign-in.
- Each profile has separate Desktop and Code configuration directories. Sign in once per profile.
- Selecting a profile asks Claude to quit normally before reopening it. Finish active Code work first.
  If Claude does not quit, CodexBar reports an error and does not force it to close.
- Conversations belong to their profile. Switching accounts does not transfer conversations.
- Opening Claude from the Dock normally opens the original environment. CodexBar detects the running
  environment rather than treating the last selected profile as active.

CodexBar verifies the Desktop account email using its current access token and Anthropic's profile
endpoint. The returned account must match Desktop's account identifier. It never uses Codex identity,
refreshes Desktop tokens, or modifies Claude's original credentials. Background verification cannot
show Keychain prompts. **Verify Account Email…** explicitly requests access to **Claude Safe Storage**
if needed. An expired token must be renewed by opening Claude itself.

Profiles live locally under `~/Library/Application Support/CodexBar/ClaudeDesktopProfiles/`.
They contain login data and must not be committed or synced as source code.

The isolation mechanism uses Claude's Electron `--user-data-dir` argument and `CLAUDE_CONFIG_DIR`.
These are not a public Desktop account-management API. Claude updates may require adjustments.
