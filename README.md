# `sf` — Minecraft server configuration & operations

Paper 26.2 · 42 plugins · offline-mode (LibreLogin) · MySQL-backed

## What's here

- [`docs/log-analysis-2026-09-16.md`](docs/log-analysis-2026-09-16.md) —
  full analysis of `latest.log`: every ERROR and WARN traced to a root cause,
  ranked fixes, and an explicit list of common "performance tips" **not** to
  apply because they break vanilla/redstone/farm mechanics.

## How to give Claude access to the server

Short version: **do not paste SFTP credentials into the chat.**

Three reasons, in order of how much they matter:

1. **It would not work anyway.** This session runs in a sandboxed cloud
   container whose only outbound path is an HTTPS proxy (CONNECT on 443).
   SFTP is SSH on port 22 — there is no route for it from here. Sharing the
   credentials would expose them and achieve nothing.
2. **The container is ephemeral.** It is destroyed after inactivity. Anything
   not committed to this repo is gone, so credentials would have to be
   re-pasted every single session.
3. **Chat transcripts persist.** A password pasted into a conversation lives
   in that conversation's history. Server credentials do not belong there.

Here are the arrangements that actually work, best first.

### Option A — this repo as the source of truth *(recommended, works today)*

You keep configs in git; I read, edit and commit them; you deploy.

1. Pull the config files down from your panel (list below) into a local folder.
2. Commit and push them to this repo.
3. Ask me for changes. I edit the files, commit, push, and explain each diff.
4. You pull and upload the changed files, then restart or `/reload`
   the affected plugin.

Benefits: every change is reviewable and revertible, you see the diff before
anything touches production, and nothing is ever applied to a live server
without you. Downside: you are the deploy step.

**Do not commit:** `server.properties` lines with `rcon.password`, any
`config.yml` containing a MySQL password or a Discord bot token, LuckPerms or
LibreLogin database credentials, `ops.json`, `usercache.json`,
`banned-ips.json`. Redact them to `REDACTED` before committing — I do not need
the real values to tune anything. A `.gitignore` is included for the obvious
ones.

### Option B — run Claude Code on your own machine *(true "manage my server")*

Install Claude Code locally, then give it the server files through a path it
can reach:

- **Panel-hosted server (Pterodactyl/Pelican, which this looks like — the
  `/home/container` paths in the log):** mount the SFTP as a local drive and
  point Claude Code at it. On Linux/macOS:
  ```bash
  sshfs -p <sftp-port> <user>@<host>:/ ~/mc-server
  cd ~/mc-server && claude
  ```
  On Windows: WinSCP "Keep remote directory up to date", or rclone mount, then
  run Claude Code in that folder. Credentials stay in your OS keychain, never
  in a chat.
- **Root VPS with SSH:** install Claude Code on the box itself and run it in
  the server directory. It then has real file access, can read live logs, and
  can restart services.

This is the setup where I can genuinely iterate — read a config, change it,
read the resulting log, adjust — instead of round-tripping through you.

### Option C — paste individual files ad hoc

Perfectly fine for one-off questions. Paste the file, I hand back the corrected
version. No setup, no persistence.

### If you do share credentials anywhere, ever

- Create a **dedicated SFTP subuser** scoped to the server, not your panel
  admin account.
- Never share RCON or a console-with-op path — that is remote code execution
  on your box, not file access.
- **Rotate the password afterwards**, on the assumption it is now public.

## Files to upload for a real tuning pass

Core:
```
server.properties                  (redact rcon.password)
config/paper-global.yml
config/paper-world-defaults.yml
world/paper-world.yml
bukkit.yml
spigot.yml
```
The JVM start command / flags (from the panel's Startup tab) — heap size, GC
flags. The log shows a 10 GB heap at 19% use, which is worth a look.

Plugin configs that the log implicates:
```
plugins/DHSupport/config.*          # chunk generation — biggest single win
plugins/VoxyServerSide/config.*     # LOD store sizing
plugins/BlueMapSkinIntegration/*    # 62 of 99 warnings
plugins/PlayTimeManager/config.yml  # Hikari maxLifetime
plugins/BreweryX/recipes.yml        # Grass -> SHORT_GRASS
plugins/TAB/groups.yml              # stray header/footer
plugins/Plan/config.yml             # GeoLite2 EULA, webserver auth
plugins/BlueMap/*.conf              # render threads
world/datapacks/2x.zip              # broken true_ending datapack
```
Source for your own plugins (`DefaultStats`, `EmeraldTradeLimiter`) if you want
the MySQL reconnect bug fixed properly.

**The most valuable single artifact** is a spark profile taken at peak player
count, not at 4 AM with one player:
```
/spark profiler --timeout 300
/spark health
```
Post the resulting link. The log tells us the server idles at 9.6 ms/tick;
spark tells us exactly which plugin and which method is spending it.

## Operating principles for this server

Agreed constraints, applied to every change:

- **No player-facing restrictions.** No world border, no build limits, no
  reduced spawn ranges, no item-despawn tweaks.
- **Vanilla mechanics preserved.** Redstone stays vanilla — eigencraft redstone
  stays off. Entity activation ranges, simulation distance, cramming and
  hopper *behaviour* are not to be traded for TPS.
- Performance is bought from **plugin overhead, chunk generation, I/O and
  rendering** — never from gameplay.
- Every change is explained, diffed, and reversible.
