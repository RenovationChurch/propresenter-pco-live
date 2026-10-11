# propresenter-pco-live

Keeps **Planning Center Services LIVE** on the same item as **ProPresenter**, so LIVE records your actual service times without anyone clicking along.

It doesn't blindly press "next". Each time ProPresenter settles on a playlist item, it works out which PCO plan item that is, reads where LIVE actually is, and moves LIVE only if they differ. Re-firing a cue does nothing. Jumping back or skipping ahead lands LIVE on the right item.

> **Status:** built and tested against mocks of both APIs. It has **not yet been run against real Planning Center or ProPresenter.** Do the test-plan steps below before using it on a Sunday. See [docs/API_NOTES.md](docs/API_NOTES.md) for what still needs confirming.

## What it does, and what it won't do

- **Dry-run is the default.** It prints what it *would* do and writes nothing to Planning Center. Add `--armed` to actually move LIVE.
- **It takes LIVE control.** Only one controller can drive LIVE. An armed run takes control when nobody has it. If a person already has control, it does **not** take over unless you pass `--take-over`.
- It **never** moves LIVE for an item that's on your ignore list, has no match, or is a header. The log says why.
- It **never** acts when ProPresenter or Planning Center can't be reached. It backs off and retries.
- It refuses to move LIVE more than `max_jump` items at once (default 3) until you type `confirm`.
- On exit it gives LIVE control back, but only if it still holds it.

## First-time setup (on the ProPresenter Mac)

1. **Python 3.11 or newer.** macOS's built-in `python3` may be older. Install from python.org or `brew install python@3.12`.
2. **Get the code and install it:**
   ```sh
   git clone https://github.com/RenovationChurch/propresenter-pco-live.git
   cd propresenter-pco-live
   python3 -m venv .venv
   source .venv/bin/activate
   pip install -e .
   ```
3. **Turn on ProPresenter's API:** ProPresenter > Settings > Network > enable Network. Note the port.
4. **Planning Center token:** create a Personal Access Token at <https://api.planningcenteronline.com/oauth/applications>. The token's user needs permission to control LIVE on the service type. Put it in your environment, **not** in any file in this repo:
   ```sh
   export PCO_APP_ID='your application id'
   export PCO_SECRET='your secret'
   ```
   To avoid retyping, put those two lines in a file outside the repo (e.g. `~/.pcosync.env`, then `chmod 600 ~/.pcosync.env`) and run `source ~/.pcosync.env`.
5. **Config:** `cp config.example.toml config.toml` and set the ProPresenter port. `config.toml` is git-ignored.
6. **Check connections (read-only):**
   ```sh
   python -m pcosync test-connection
   python -m pcosync service-types           # find your service type ID
   ```
   Put the service type ID in `config.toml` under `[pco] service_type_id`.

## Check the mapping (read-only)

Open the service playlist in ProPresenter and click any item in it. Then run:

```sh
python -m pcosync items      # the PCO plan's items, in order
python -m pcosync mapping    # each ProPresenter playlist item -> PCO item
```

Every item that should move LIVE should show a PCO title. Anything that shouldn't (loops, announcement slides, backups) should show `-- no move --`. Fix mismatches with `[match.ignore]` and `[match.aliases]` in `config.toml`.

How matching works, in order:
1. **Ignore list:** never moves LIVE.
2. **Headers:** never move LIVE.
3. **Aliases:** your explicit ProPresenter-name → PCO-title map.
4. **Title:** case, punctuation, accents and `&`/`and` are ignored. If two plan items share a title (e.g. two "Prayer" items), the 2nd "Prayer" in the playlist maps to the 2nd in the plan.
5. **Position (fallback):** for playlists ProPresenter built from the PCO plan. Entries marked PCO-linked map by position, and only if their count equals the plan's item count. Items you added by hand never match by position.

## Run it

**Dry-run (safe any time):**
```sh
python -m pcosync run
```
Click through the playlist. You'll see lines like:
```
[dry_run] ProPresenter 'Goodness Of God' -> PCO 'Goodness of God'; LIVE on 'Way Maker': would move forward 1 item(s) [title]
```

**Armed (moves LIVE):**
```sh
python -m pcosync run --armed
```

**Commands while running** (type and press Enter):

| Command | What it does |
|---|---|
| `status` | Show mode, service time, limits |
| `pause` / `resume` | Stop / restart moving LIVE |
| `confirm` | Allow the next move once even if it's bigger than `max_jump` |
| `next-service` / `prev-service` | Target the next/previous service time (e.g. 11:00 after 9:00) |
| `auto-service` | Go back to following whichever service time LIVE is on |
| `reload` | Re-fetch the plan (after editing it in PCO) |
| `quit` | Stop. Also releases LIVE control. Ctrl-C works too. |

**Stopping:** `quit` or Ctrl-C. Control is released if the tool holds it.

### Multiple service times

LIVE runs through the 9:00 items, then the 11:00 items. When the 11:00 service starts, ProPresenter goes back to item 1, which looks like a big jump *back* in the 9:00 service. `max_jump` refuses that move. Type `next-service` and LIVE moves forward into the 11:00 service. You can also start with `--service-time 2`.

## Testing on a dummy plan (do this before any Sunday)

1. In PCO, create a throwaway plan (not a Sunday plan) with a few items and a header.
2. `python -m pcosync --plan <TEST_PLAN_ID> mapping` and check the output.
3. `python -m pcosync --plan <TEST_PLAN_ID> run --armed` and click through ProPresenter: forward, re-fire, jump back, skip ahead, an ignored item.
4. In PCO, check the plan's recorded times and the **LIVE: Recorded Times** report. Note whether API-driven moves record the same as manual clicks.
5. **Reset** the rehearsal times in LIVE before the real service.

## Service-day checklist

- [ ] ProPresenter open, Network enabled, service playlist loaded.
- [ ] `source ~/.pcosync.env`
- [ ] `python -m pcosync mapping`: every expected item maps.
- [ ] Rehearsal times reset in LIVE.
- [ ] Nobody else needs LIVE control (the tool will hold it).
- [ ] `python -m pcosync run --armed`
- [ ] Between services: `next-service` when the second service starts.
- [ ] After service: `quit`.

## Run on login (optional)

`docs/com.renovationchurch.pcosync.plist` is a launchd example. Edit the paths, copy it to `~/Library/LaunchAgents/`, then `launchctl load ~/Library/LaunchAgents/com.renovationchurch.pcosync.plist`. It runs **dry-run** unless you add `--armed` to its arguments. Keep secrets out of the plist if the repo is shared: the example sources `~/.pcosync.env`.

## Development

```sh
pip install -e '.[dev]'
pytest
```

Try it with no ProPresenter or PCO: `python tools/mock_servers.py` serves fakes of both. Then, in another terminal:
```sh
export PCO_BASE_URL=http://127.0.0.1:8765 PCO_APP_ID=x PCO_SECRET=y
python -m pcosync --service-type 111 --plan 222 run --armed
```
Type item numbers into the mock-server terminal to "fire" ProPresenter cues.

Logs: terminal plus `logs/pcosync.log` (rotated at 2 MB, 5 kept). Credentials are never printed. A log filter also redacts them if one ever slips into a message.
