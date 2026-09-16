# Server log analysis — `latest.log` (04:00:22 → 12:54:54)

Paper 26.2-87 · MC 26.2 · Java 25 (Temurin) · 42 plugins · offline-mode · port 25582

## 0. Headline

The server is **not currently lagging**. The spark health report at 10:19 shows:

```
TPS  (5s/10s/1m/5m/15m): 20.0, 20.0, 20.0, 20.0, 20.0
Tick durations (10s):    min 6.5 / med 9.6 / 95% 11.5 / max 18.9 ms
CPU:                     2-3% system, 2-3% process
Memory:                  1.9 GB / 10.0 GB (19%)
Disk:                    418.3 GB / 1.8 TB (22%)
```

But read the tick durations again: **9.6 ms median with one player online.**
A vanilla-ish Paper server idling with 1 player normally ticks in 1–3 ms.
You are burning ~50% of the 50 ms tick budget before the server does any real
work. That is the whole performance story — there is a large fixed per-tick
cost from the plugin stack, and it will be what breaks first as the player
count climbs toward the 67-slot max.

Paper also reports `[MoonriseCommon] Paper is using 2 worker threads, 1 I/O
threads`. Moonrise sizes that pool from the visible core count, so the
container is almost certainly on ~4 vCPU or fewer. With chunk loading,
BlueMap, two LOD plugins and CoreProtect all competing for 2 workers, chunk
I/O is the likely first bottleneck under load — not the main thread.

Error volume: **4 ERROR + 99 WARN lines**, but only ~6 distinct root causes.
62 of the 99 warnings are one single problem (§1).

---

## 1. Mojang profile lookups — 62 warnings, HTTP 429 (the noisiest issue)

```
[04:00:42] [Download-2/WARN]: Couldn't look up profile properties for 21a088a3-cb70-32ac-a41b-d1ead302d726
MinecraftClientHttpException[type=HTTP_ERROR, status=429, response=null]
	at com.mojang.authlib.yggdrasil.YggdrasilMinecraftSessionService.fetchProfileUncached
	at org.bukkit.craftbukkit.profile.CraftPlayerProfile.getUpdatedProfile
```

**What happened:** 62 lookups against 50 unique UUIDs, fired in a ~6 second
burst between 04:00:42 and 04:00:48 — i.e. during plugin enable, before
`Done (26.713s)`. Mojang rate-limited them (429). One also failed with a raw
`SocketTimeoutException: Read timed out`.

**Why it can never fully succeed:** of those 50 UUIDs,

- **21 are version-3 UUIDs** — offline-mode UUIDs, generated locally from the
  username hash. They do not exist at Mojang. Every lookup for them is
  guaranteed to 404/fail, forever.
- 29 are version-4 (real premium accounts) and *would* resolve — except the
  21 doomed requests help blow the rate limit, so the good ones get 429'd too.

**Who is doing it:** the burst lines up exactly with `BlueMapSkinIntegration`
enabling (`Enabled SkinsRestorer` / `Enabled Mojang` at 04:00:44) — it walks
the known-player set and resolves every head. The stack has no plugin frame
because the work is handed to `CompletableFuture`, but the timing is
unambiguous.

**Fix (pick one):**

1. In `BlueMapSkinIntegration`'s config, disable the **Mojang** skin source and
   leave only **SkinsRestorer**. SkinsRestorer already has its own MySQL skin
   cache (`Connected to MySQL!` at 04:00:36) and is the correct source of truth
   on an offline-mode server.
2. If the plugin has no such toggle: drop it. BlueMap can render heads from
   a local skin cache directory instead.
3. Belt-and-braces: Paper's `config/paper-global.yml` →
   `misc.region-file-cache-size` is unrelated, but
   `proxies.velocity`/`player-auto-save` aside, the relevant knob is that
   nothing else should be calling `getUpdatedProfile()` on offline UUIDs.

This one change removes ~63% of all warnings in the file and ~6 seconds of
startup network stalling.

> Note: `BlueMapSkinIntegration v1.0.0` also earns a Paper nag for printing to
> `System.out` instead of its logger, its plugin.yml website is literally
> `http://www.example.com`, and its last release is 1.0.0. It is an
> unmaintained plugin doing a job SkinsRestorer already does.

---

## 2. Broken datapack — 3 ERRORs, `true_ending` + `2x.zip`

```
[ServerMain/WARN]: Non [a-z0-9_.-] character in namespace .DS_Store in pack ./world/datapacks/2x.zip, ignoring   (x2)
[Worker-Main-1/ERROR]: Couldn't parse data file 'true_ending:time/200'      from 'true_ending:predicate/time/200.json'
[Worker-Main-1/ERROR]: Couldn't parse data file 'true_ending:time/daytime'  from 'true_ending:predicate/time/daytime.json'
[Worker-Main-1/ERROR]: Couldn't parse data file 'true_ending:kill_dragon'   from 'true_ending:advancement/kill_dragon.json'
```

These are the only true ERRORs at the Minecraft level, and they mean **three
data files are silently not loaded** — so whatever `true_ending` is supposed to
do, part of it is dead right now.

Two separate problems:

**a) `.DS_Store` in `2x.zip`** — the zip was built on macOS and carries Finder
metadata at the archive root, which Minecraft reads as a namespace. Harmless
but repeatable noise. Rebuild the zip without it:

```bash
zip -r 2x.zip . -x '.DS_Store' -x '__MACOSX/*' -x '*/.DS_Store'
```

**b) `true_ending` is written against an older datapack format.**

- `predicate/time/200.json` and `time/daytime.json` use
  `{"condition":"minecraft:time_check","value":...,"period":24000}`.
  26.2 rejects it with *"No key clock in MapLike"* — the condition now
  requires a `clock` field that the file does not have.
- `advancement/kill_dragon.json` nests
  `"predicate":{"type":"minecraft:ender_dragon"}`, and 26.2 tries to resolve
  `minecraft:type` as an `entity_sub_predicate_type` and fails.

Both need rewriting for the 26.2 schema, and the pack's `pack.mcmeta`
`pack_format` should be bumped to match. Send me the datapack folder and I
will convert the files.

---

## 3. MySQL connections dying — the most likely source of real data loss

```
[04:52:37] [DefaultStats/WARN] Failed to save stats for Vexeryn: Communications link failure
  The last packet successfully received from the server was 2,564,563 milliseconds ago.
[07:17:30] [DefaultStats/WARN] Failed to save stats for NASTIA125: Communications link failure
  ... 8,692,222 milliseconds ago.
[12:07:36] [DefaultStats/WARN] Failed to save stats for NASTIA125: Communications link failure
  ... 2,549,678 milliseconds ago.
[06:58:58] [PlayTimeManager/WARN] HikariPool-1 - Failed to validate connection com.mysql.cj.jdbc.ConnectionImpl@84fbc24
  (No operations allowed after connection closed.). Possibly consider using a shorter maxLifetime value.
```

Look at the idle times: 2,564,563 ms = **42 minutes**. 8,692,222 ms = **2h 25m**.
Your MySQL server is closing idle connections (`wait_timeout`, default 8h but
clearly set much lower here, or a proxy/firewall is culling idle TCP), and two
plugins are holding a connection open across that gap and only discovering it
is dead when they try to write.

- **PlayTimeManager** uses HikariCP and *recovers* — Hikari detects the dead
  connection, logs the warning, and replaces it. Annoying, not fatal.
- **DefaultStats** (your own plugin, v1.0.0) apparently holds a bare JDBC
  connection with no pool and no validation, so the write is **simply lost**.
  Three players' stats were dropped in this log alone.

**Fixes:**

1. Raise `wait_timeout` / `interactive_timeout` on the MySQL server above your
   longest idle gap (e.g. `28800`), *and*
2. Set Hikari `maxLifetime` to ~30s below `wait_timeout` in PlayTimeManager's
   config (if `wait_timeout=1800`, use `maxLifetime: 1770000` ms).
3. In `DefaultStats`, replace the bare connection with HikariCP (or at minimum
   validate with `Connection.isValid(1)` and reconnect before each write, and
   retry the write once on `CommunicationsException`). Send me the source and
   I'll patch it — this is a ~20 line change that stops silent stat loss.

Same treatment applies to SkinsRestorer, Plan and LibreLogin, which all use the
same MySQL instance — they just did not happen to hit an idle window today.

---

## 4. Distant-Horizons / LOD stack — the biggest performance and disk risk

You are running **two** server-side LOD providers at once:

- `DHSupport (DHS) 0.14.0` — serves Distant Horizons clients
- `VoxyServerSide (VSS) 0.14.0` — serves Voxy clients

Both register overlapping dirty-chunk listeners on the *same* events
(`BlockPlace`, `BlockBreak`, `BlockExplode`, `PistonExtend`, …). Every block a
player places is being accounted twice.

And DHS is configured to **generate new chunks**:

```
[DHS/WARN] Chunk generation is enabled. New chunks will be generated as needed to complete
           LOD generation. This could significantly increase the size of your world.
[DHS/WARN] If you understand what this means and would like to disable this warning,
           set generate_new_chunks_warning to false in your config.
[DHS/WARN] Custom biomes are not supported on this server.
```

This is worldgen — the single most expensive thing a server can do — running on
demand to fill in LOD for terrain no player has ever visited. On a box with
2 Moonrise worker threads. Your world is already **418 GB**, and a player
logged in at `the_end` x=**-371,245** — so people genuinely do travel far, and
DHS will happily generate a cone of new chunks around every one of them.

VSS is also carrying a large state:

```
[VSS] Loaded 1917899 timestamp cache entries from world/data/lss-timestamps.bin
[VSS] LOD store active (lodStore=on). It stores served LOD bytes under <world>/vss-lod/
      and, once fully warmed, occupies roughly as much space as the region files themselves
```

1.9 M entries in RAM at startup, and a disk store sized "roughly as much as the
region files" — i.e. it wants to roughly **double** a 418 GB world.

**Recommendations (none of these touch gameplay mechanics):**

1. **Set `generate_new_chunks: false` in DHS.** LOD then only covers chunks
   that actually exist. This is the single highest-value change in this
   document for CPU and disk. Players lose nothing they built — only
   speculative terrain they have never visited.
2. **Pick one LOD plugin.** Check which mod your players actually use
   (Distant Horizons vs Voxy). If it is overwhelmingly one, drop the other.
   If you truly need both, accept the cost but definitely do #1.
3. Reconsider `lodStore=on` in VSS given your disk trajectory — 418 GB on a
   1.8 TB volume with two systems that both want to grow.
4. Both plugins ship x-ray masking (`maxY=64`, `source=paper-config`) — that is
   already correct, leave it.

---

## 5. Player timeouts — worth investigating, may be caused by §4

```
[10:53:12] NASTIA125 lost connection: Timed out
[11:25:06] NASTIA125 lost connection: Timed out
[12:42:51] NASTIA125 lost connection: Timed out
```

Three timeouts for one player in a session where **TPS never left 20.0**. The
server was not lagging, so this is not a tick-rate problem. Two candidates:

1. That player's own connection (193.30.240.177). Most likely; other players
   disconnected cleanly with `Disconnected`.
2. **LOD streaming saturating their downlink.** The health report shows
   `eth0 tx 48.5 KB/s` vs `rx 3.9 KB/s` with essentially one player online —
   a 12:1 outbound ratio. DHS/VSS pushing LOD payloads to a client on a weak
   connection can stall the vanilla keepalive and trip the timeout. If the
   timeouts stop after §4's changes, that was it.

Also present, low severity:

```
[04:03:02] orange_k1t moved wrongly!   (x4, all within ~80 seconds)
```

Four in one burst for one player and never again — consistent with a brief
client hiccup or a boat/elytra edge case. Not actionable at this volume. If it
ever becomes constant for many players, *then* it is a plugin teleport bug.

---

## 6. Configuration errors that are just wrong, and free to fix

| Log line | Problem | Fix |
|---|---|---|
| `[BreweryX] ERROR: grass: Could not find material: Grass` (x2, kills 2 cauldron recipes) | `GRASS` was renamed `SHORT_GRASS` in 1.20.3 | Edit BreweryX `recipes.yml`: `Grass` → `SHORT_GRASS` |
| `[BreweryX] Minecraft version: Unknown` / `not known to Brewery!` | BreweryX build `3.7.0;HEAD` predates MC 26.2 | Update BreweryX, or accept the risk |
| `[TAB] [WARN] [groups.yml] Unknown property "header"/"footer" for group "example_group"` | `header`/`footer` are not group properties | Remove them from `example_group`, or move to the header/footer feature config. This is leftover example config |
| `[VotingPlugin] Detected no voting sites` + `No VotifierEvent found` + `Failed to hook into vault economy` | VotingPlugin is installed and enabled but completely unconfigured — it does nothing except cost tick time and register a PAPI expansion | Configure vote sites + install NuVotifier, **or remove the plugin** |
| `[Plan] Downloading GeoLite2 requires accepting GeoLite2 EULA` → `ERROR: Failed to enable geolocation` | Unaccepted EULA | Set `Data_gathering.Accept_GeoLite2_EULA: true`, or set `Data_gathering.Geolocations: false` to stop the error |
| `Oraxen \| Found invalid texture-path ... (12x crossbow trims)` → `Pack contains malformed texture(s) and/or model(s) ... otherwise the resourcepack will be broken` | The `tooltrims` pack references 12 `item/trims/crossbow_*` textures that do not exist | Add the missing PNGs or remove those model files. Oraxen is currently shipping a knowingly-broken pack to every player |
| `Oraxen \| Generated Jukebox datapack. A server restart is required for this feature to work.` | Pending restart for a generated datapack | Already handled by your nightly restart |
| `Nag author(s): '[Cerothen]' of 'BlueMapSkinIntegration'` | See §1 | Removing the plugin fixes this too |
| `*** Currently you are 37 builds behind ***` | Paper 26.2-87 vs latest | Update Paper. 37 builds is a lot of upstream bugfixes, several of them usually chunk-system and performance work |
| `[Skript] A new version of Skript is available: 2.16.2` / `[PlayTimeManager] Latest version: 3.6.6` / `[Plan] New Release (5.8.3638)` | Three plugins behind | Routine updates |

---

## 7. Security notes (not errors, but you should know)

- **`Plan` webserver on port 8804 with `User Authorization Disabled! (Not secure over HTTP)`.**
  If 8804 is reachable from the internet, anyone can browse your full player
  analytics — IPs, playtimes, sessions. Either firewall it to localhost or
  enable Plan's authentication.
- **`BlueMap` webserver bound to all interfaces on 25585**, `Oraxen` pack
  server on 25592 serving over plain HTTP from the raw IP
  (`http://194.54.88.19:25592/pack.zip`). Fine if intended; note that the
  resource-pack URL leaks the origin IP to every client, which matters if you
  ever put the server behind DDoS protection.
- `SERVER IS RUNNING IN OFFLINE/INSECURE MODE!` and
  `[voicechat] Running in offline mode - Voice chat encryption is not secure!`
  are **expected** — you run LibreLogin + a limbo world + SkinsRestorer, so
  this is a deliberate cracked-server setup, not a misconfiguration. Just make
  sure the server port is only reachable via your proxy if you have one, so
  nobody bypasses LibreLogin.
- `[DiscordSRV] Console channel ID was invalid, not forwarding console output`
  — arguably a good thing. Console-to-Discord leaks IPs and tokens.

---

## 8. Recommended order of work

Ranked by (impact ÷ risk). Nothing here restricts players, changes redstone,
or alters vanilla mechanics.

**Do first — free wins, zero gameplay impact**

1. DHS `generate_new_chunks: false` — biggest CPU + disk win (§4)
2. BlueMapSkinIntegration: Mojang source off, or remove plugin — kills 62 warnings (§1)
3. MySQL `wait_timeout` up + Hikari `maxLifetime` down — stops silent stat loss (§3)
4. Update Paper (37 builds), Skript, PlayTimeManager, Plan
5. Remove or configure VotingPlugin — it is pure overhead today (§6)

**Do next — needs a decision from you**

6. Choose one LOD plugin (DHS or VSS) instead of both (§4)
7. Patch DefaultStats to use a connection pool (§3) — send me the source
8. Fix the `true_ending` datapack for 26.2 (§2) — send me the folder
9. Fix Oraxen's 12 missing crossbow-trim textures (§6)

**Then — the real tuning pass**

10. Capture a proper profile while populated and tune from data, not guesses:
    ```
    /spark profiler --timeout 300
    ```
    Run it at peak player count, not at 04:00 with one player. Post the link.
    That 9.6 ms idle median (§0) has a cause, and spark will name the exact
    plugin and method. Everything above is inference from a log; spark is
    measurement.

**Explicitly NOT recommended** — these are the usual "performance guide"
advice and every one of them breaks something you said you want to keep:

| Common advice | Why not, for your server |
|---|---|
| Lower `entity-activation-range` | Breaks mob farms, iron farms, villager breeders |
| Lower `simulation-distance` | Stops farms running when a player is nearby-but-not-adjacent; changes chunk loading behaviour players build around |
| `use-faster-eigencraft-redstone: true` | Claims parity but has known update-order differences. You asked for vanilla redstone — leave it **off** |
| `armor-stands.tick: false` | Armor stands stop falling/reacting to water. Breaks builds and ImageFrame/ArmorStandEditor setups |
| `alternative-item-despawn-rate` / reduced `item-despawn-rate` | Changes item duplication/collection timing farms rely on |
| `fix-climbing-bypassing-cramming-rule` | Changes cramming behaviour, breaks some farms |
| `mob-spawn-range` reduction | Directly reduces farm rates |
| World border / pregen trim | Would restrict the exploration your players clearly do (someone is at End x=-371,245) |

`view-distance` is the one distance knob that is safe to lower — it only
affects how far clients *render*, not what the server simulates. And with DHS
or VSS serving LOD, players will not even notice; that is precisely what those
plugins are for. Lowering `view-distance` to 6–8 while keeping
`simulation-distance` where it is gives you a large chunk-system saving with
zero mechanical change.

**Safe plugin-level win:** `paper-world-defaults.yml` →
`hopper.disable-move-event: true`. This skips firing
`InventoryMoveItemEvent` for hopper transfers. Vanilla hopper behaviour is
completely unchanged — only plugins that *listen* to that event are affected.
Verify none of your plugins depend on it (CoreProtect does not log hopper
moves by default), then enable it. Hoppers are usually the top main-thread
cost on a survival server.
