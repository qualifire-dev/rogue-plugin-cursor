# Installing Rogue Security for Cursor

Rogue Security AIDR sits inside Cursor and observes every agent event — prompts, tool calls, shell commands, MCP invocations, file reads, subagents — forwarding each one to Rogue's detection engine for prompt-injection, secret-exfiltration, and destructive-command analysis. Allow / ask / deny decisions come from your Rogue org configuration; there are no client-side policy knobs to misconfigure.

There are two ways to install:

1. **Org-wide** via a Cursor Team Marketplace — recommended for security teams that want every developer covered automatically, with no opt-out.
2. **Per-developer** via a one-line installer — fastest path for an individual to try Rogue on their own machine.

---

## 1. Org-wide install (Cursor Team Marketplace)

> Requires a **Cursor Teams or Enterprise** plan (Cursor 2.6+). Only Cursor admins can add team marketplaces.

In the Cursor admin dashboard:

1. Open **Settings → Plugins**.
2. Under **Team Marketplaces**, click **Import**.
3. Paste the repository URL:
   ```
   https://github.com/qualifire-dev/rogue-plugin-cursor
   ```
4. Cursor parses the marketplace and shows the `rogue` plugin. Set a marketplace **name** (e.g. "Rogue Security") and **description**.
5. Under **Team Access**, choose which distribution groups receive the plugin — typically all developers.
6. Set the `rogue` plugin distribution mode to **Required**:

    | Mode          | Behavior                                                                |
    |---------------|-------------------------------------------------------------------------|
    | Default Off   | Visible in the marketplace; developer chooses to install.               |
    | Default On    | Installed automatically; developer can uninstall.                       |
    | **Required**  | Installed automatically; developer **cannot** uninstall or disable it.  |

   Cursor's own guidance is to reserve **Required** for security-critical tools — that's the right mode here.

If your org uses SCIM with Cursor, manage distribution groups in your IdP (Okta, Entra, etc.) — Cursor syncs group membership automatically, so onboarding a new engineer to your "Engineering" group will deploy Rogue to their Cursor install on next launch.

> **GitHub Enterprise Server (self-hosted)**: register a Cursor GHE app at `cursor.com/dashboard?tab=integrations` and install it in your organization before importing the marketplace.

### Distributing credentials

Each install needs `ROGUE_API_KEY` (and optionally `ROGUE_ACTOR_EMAIL` and `ROGUE_ACTOR_NAME`) to authenticate against the Rogue API. Marketplaces don't ship secrets, so pick one of the following:

- **MDM-managed system env file** (*recommended for Enterprise*) — push `/etc/rogue/env` (mode 600) via Jamf, Intune, or Kandji. No developer action required; works the moment Cursor launches.
- **Per-user setup command** — developers run `/rogue:setup` inside Cursor once after install, which writes `~/.rogue-env`. Works well for smaller teams.
- **MDM provisioning script** — push a script that runs the one-line installer in `--non-interactive` mode with `ROGUE_API_KEY` pre-set.

API keys are issued at <https://app.rogue.security/settings/api-keys>.

### Plan sizing

| Plan       | Team marketplaces |
|------------|-------------------|
| Teams      | 1                 |
| Enterprise | Unlimited         |

---

## 2. Per-developer install (one-line)

For an individual developer on macOS:

```bash
curl -fsSL https://raw.githubusercontent.com/qualifire-dev/rogue-plugin-cursor/main/install.sh | bash
```

The installer:

- Prompts for an API key (or reads `ROGUE_API_KEY` from the environment).
- Validates the key against `https://api.rogue.security`.
- Writes `~/.rogue-env` (mode 600).
- Installs the plugin into `~/.cursor/plugins/local/rogue/`.
- Enables a background auto-update that runs at most once every 24h.

Non-interactive (suitable for CI or provisioning scripts):

```bash
curl -fsSL https://raw.githubusercontent.com/qualifire-dev/rogue-plugin-cursor/main/install.sh \
  | ROGUE_API_KEY=rsk_xxxxxxxx \
    ROGUE_ACTOR_EMAIL=alice@yourco.com \
    ROGUE_ACTOR_NAME='Alice Engineer' \
    bash -s -- --non-interactive
```

Supported flags: `--api-key`, `--email`, `--name`, `--api-url`, `--non-interactive`.

After install, **fully quit Cursor and reopen**, then run `/rogue:status` to verify.

---

## Configuration reference

These environment variables are read from `~/.rogue-env` (or `/etc/rogue/env` for MDM-managed installs):

| Variable               | Required | Purpose                                                          |
|------------------------|----------|------------------------------------------------------------------|
| `ROGUE_API_KEY`        | Yes      | API key from <https://app.rogue.security/settings/api-keys>.     |
| `ROGUE_ACTOR_EMAIL`    | No       | Identifies the developer in the AIDR dashboard.                  |
| `ROGUE_ACTOR_NAME`     | No       | Display name in the dashboard.                                   |
| `ROGUE_BASE_URL`       | No       | Override the API endpoint (default `https://api.rogue.security`). |
| `ROGUE_AUTO_UPDATE`    | No       | Set `0` to disable the background updater (one-line install only). |
| `ROGUE_PLUGIN_VERSION` | No       | Pin to a specific release (e.g. `v1.0.0`).                       |

Both file locations use mode 600. The system-wide `/etc/rogue/env` takes precedence when present.

---

## Verifying the install

1. Fully restart Cursor.
2. Run `/rogue:status` inside Cursor — you should see `API: reachable` and a non-zero hook count.
3. Send any prompt in agent mode. Within a few seconds it should appear at <https://app.rogue.security/aidr>.

---

## FAQ

**Can I enforce this plugin so developers can't disable it?**
Yes — via a Cursor Team Marketplace with the `rogue` plugin set to **Required**. The per-developer one-line install is not enforceable on its own (developers can disable plugins they installed themselves). Pair the marketplace install with an MDM-pushed `/etc/rogue/env` and the plugin runs on every Cursor session with no developer opt-out.

**Does the plugin block developers if the Rogue API is unreachable?**
No. Rogue's plugin is fail-open by design: missing API key, network failure, non-200 responses, or malformed bodies all result in no detection and no block. Developers are never stopped by Rogue infrastructure issues. Policy decisions only apply when the API responds successfully.

**How does the plugin update itself?**
- **Marketplace install:** Cursor manages updates from the marketplace repository automatically.
- **One-line install:** the plugin runs an auto-updater on each Cursor `sessionStart`, rate-limited to once per 24h. Disable it by setting `ROGUE_AUTO_UPDATE=0`, or pin a version with `ROGUE_PLUGIN_VERSION=v1.0.0`.

**What gets stored on the developer's machine?**
- Plugin files (managed by Cursor for marketplace installs, or `~/.cursor/plugins/local/rogue/` for the one-line install).
- Credentials at `~/.rogue-env` or `/etc/rogue/env` (mode 600).

**Is the source code reviewable before deployment?**
Yes — the plugin is an open repository at <https://github.com/qualifire-dev/rogue-plugin-cursor>. Security teams typically review it before importing it as a team marketplace.

**Is there a way to mark a detection as a false positive?**
Yes — prepend `rgx!` to any prompt. That request is allowed through and the previous detection is flagged as a false positive in your AIDR dashboard. Per-prompt only.

---

Questions or rollout help: <support@rogue.security>.
