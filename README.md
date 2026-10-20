# PCOSync (propresenter-pco-live)

Keeps **Planning Center Services LIVE** on the same item as **ProPresenter**, so LIVE records your actual service times without anyone clicking along.

PCOSync is a native macOS menu-bar app. It runs in the background on the ProPresenter Mac. You monitor and configure it from a web dashboard at **http://127.0.0.1:8642**.

It doesn't blindly press "next". Each time ProPresenter settles on a playlist item, it works out which PCO plan item that is, reads where LIVE actually is, and moves LIVE only if they differ. Re-firing a cue does nothing. Jumping back or skipping ahead lands LIVE on the right item.

> **Status:** the Planning Center side has been checked against the real API with read-only calls (see [docs/API_NOTES.md](docs/API_NOTES.md)). The sync engine is covered by tests and has been run end to end against mock servers. Not yet tested: a real ProPresenter, and any armed run (one that writes to LIVE) against real Planning Center. Do the test plan below before using it on a Sunday.

## What it does, and what it won't do

- **Dry-run is the default.** It shows what it *would* do and writes nothing to Planning Center. You press **Arm** to let it move LIVE.
- **It takes LIVE control.** Only one controller can drive LIVE. When armed, it takes control if nobody has it. If a person already has control, it does **not** take over unless you turn on "Take LIVE control even if a person already has it".
- It **never** moves LIVE for an item on your ignore list, an item with no match, or a header. The activity feed says why.
- It **never** acts when ProPresenter or Planning Center can't be reached. It retries and shows the problem on the dashboard.
- It refuses to move LIVE past more than *max jump* matched items at once (default 3) until you press **Confirm big move**. Plan items with no ProPresenter slide (a host prayer, a baptism setup) don't count: LIVE passes over them on its way to the next matched item.
- When armed, it only moves LIVE around service times: from 20 minutes before each service until 3 hours after it starts. Rehearsals, run-throughs and mid-week tests never record times.
- When you stop or quit it, it gives LIVE control back, but only if it still holds it.

## Install (on the ProPresenter Mac)

You need macOS 13 or newer and Apple's Command Line Tools. You don't need the full Xcode app or an Apple developer account.

1. **Command Line Tools** (skip if you already have them):
   ```sh
   xcode-select --install
   ```
2. **Get the code, build and install:**
   ```sh
   git clone https://github.com/RenovationChurch/propresenter-pco-live.git
   cd propresenter-pco-live
   scripts/install.sh
   ```
   This builds `PCOSync.app`, copies it to `/Applications` and starts it. An icon appears in the menu bar, and the dashboard opens in your browser on first run.
3. **Start at login:** click the menu-bar icon › **Open at Login**.

To update later, run `git pull && scripts/install.sh`.

**Alternative: download a prebuilt app.** Every push builds `PCOSync.app` on GitHub Actions ("macOS build" workflow › *PCOSync-app* artifact). It isn't notarized. After unzipping, run `xattr -dr com.apple.quarantine PCOSync.app` (or right-click › Open) before the first launch.

## First-time setup (in the dashboard)

Open **http://127.0.0.1:8642** (or menu-bar icon › **Open Dashboard…**) and go to **Settings**.

1. **ProPresenter:** ProPresenter › Settings › Network: enable Network and note the port. Enter the host (`127.0.0.1` if it's this Mac) and the port.
2. **Planning Center credentials:** create a Personal Access Token at <https://api.planningcenteronline.com/oauth/applications>. The token's user needs permission to control LIVE on the service type. Paste the Application ID and Secret, then click **Save & test**. They're checked before saving. They're stored only on this Mac, readable only by your user account, and are never shown again.
3. **Plan:** leave it on **Automatic**. It follows whichever plan with songs is on now or comes up next, in any service type: the Sunday plan most weeks, a multi-day Easter plan, or a Christmas plan in Other Events. It moves on to the next plan by itself after the last service. Plans without songs (workshops, team nights) are skipped. (To pin one service type, pick "Next upcoming plan in the service type" and choose the **Service type**.)
4. Click **Save settings**, then **Test connections**.

## Check the mapping (read-only)

Open the service playlist in ProPresenter and click any item in it. Then open the **Mapping** tab.

Every item that should move LIVE should show a PCO item, with how sure the match is (*sure*, *likely* or *best guess*). Anything that shouldn't (loops, announcement slides, backups) should show `— no move —`. Below the table, **Plan items with no ProPresenter slide** lists what LIVE will pass over. Yellow banners flag things to double-check, like "ProPresenter says Week 3 but the plan says Week 4". Fix mismatches in **Settings › Matching**:

- **Never move LIVE for:** one name per line. Matching ignores case and punctuation. Lines starting with `regex:` are regular expressions.
- **Aliases:** one `ProPresenter name = PCO title` per line.

How matching works, in order:
1. **Ignore list:** never moves LIVE.
2. **Headers:** never move LIVE.
3. **Aliases:** your explicit ProPresenter-name → PCO-title map. Always wins.
4. **Best guess:** each playlist entry is compared with each plan item:
   - **Title.** Case, punctuation, accents, plurals and `&`/`and` are ignored. The person after a dash is ignored too ("Baptisms" = "BAPTISMS - Joey"), joined words count ("Pre-roll" = "PREROLL SLIDES"), and one name may contain the other ("Bumper" = "SERMON BUMPER", "Closing" = "HOST CLOSING - Jon").
   - **Description.** Most words of the name appear at the top of the item's description in PCO ("Gospel of John - Week 3" = "MESSAGE - Jon", described "Gospel of John Week 4").
   - **Position.** For playlists ProPresenter built from the PCO plan: the Nth PCO-linked entry = the Nth plan item, when the counts agree.

   Then the whole playlist is lined up against the whole plan **in order**. That's what keeps repeated songs straight: the 1st "What A Worthy Name" in the playlist goes to the one before the baptisms, the 2nd to the one after. Entries you add by hand in between don't throw anything off.
5. **A song used twice but in the playlist once:** LIVE goes to the next copy ahead of where it is, so the same slide works for the opener and the closer.

## Running it

The dashboard shows what ProPresenter is on, where LIVE is, who controls LIVE, the plan with LIVE highlighted, and a feed of every decision.

| Control | What it does |
|---|---|
| **Start dry-run** | Follow ProPresenter and report what it would do. Writes nothing. |
| **Arm (move LIVE)…** | Follow ProPresenter and move LIVE. Asks to confirm first. |
| **Stop** | Stop following. Releases LIVE control if PCOSync holds it. |
| **Pause / Resume** | Keep running but don't move LIVE. |
| **Confirm big move** | Allow the next move once, even if it's bigger than max jump. |
| **Service time: Previous / Next / Automatic** | Override the service time (e.g. 10:50 after 9:00). Rarely needed: **Automatic** (the default) follows LIVE and starts the next service on its own. |
| **Reload plan** | Re-fetch the plan after editing it in PCO. It also refreshes every 5 minutes on its own. |

The menu-bar icon shows the state at a glance. **ARMED** in red means it's moving LIVE, **DRY** means dry-run, and a warning triangle means it can't reach ProPresenter or Planning Center. The same controls are in its menu.

**Start syncing when the app launches** (on by default) starts it in dry-run at login. **…and start armed** makes it arm itself at launch. Leave that off unless you want LIVE to move without anyone pressing Arm.

### Multiple service times

LIVE runs through the 9:00 items, then the 10:50 items. From 20 minutes before a service starts (preroll), ProPresenter going back to the start of the playlist moves LIVE into that service instead of rewinding the last one. If the 9:00 runs long, moving *forward* (the closing song at 10:35) stays in the 9:00. This works for any number of services over any number of days (Easter, Christmas).

If you ever need to, **Previous** / **Next** under Service time override it, and **Automatic** goes back to the clock. Settings › Service times sets the lead time and how long a service can run.

## Testing on a dummy plan (do this before any Sunday)

1. In PCO, create a throwaway plan (not a Sunday plan) with a few items and a header.
2. In Settings, pick its **Service type**, set **Plan** to that test plan (click "Load plans"), turn off **Only move LIVE around service times** (unless the test plan has a service time right now), and save. Check the **Mapping** tab.
3. **Arm** and click through ProPresenter: forward, re-fire, jump back, skip ahead, an ignored item. Watch the activity feed.
4. In PCO, check the plan's recorded times and the **LIVE: Recorded Times** report. Note whether API-driven moves record the same as manual clicks.
5. **Stop**, set Plan back to **Automatic**, turn **Only move LIVE around service times** back on, and save.

## Service-day checklist

- [ ] ProPresenter open, Network enabled, service playlist loaded.
- [ ] PCOSync running (menu-bar icon), dashboard shows both dots green.
- [ ] **Mapping** tab: every expected item maps.
- [ ] **Mapping** tab: no yellow banners, and the "no ProPresenter slide" list looks right.
- [ ] Nobody else needs LIVE control (PCOSync will hold it).
- [ ] **Arm**.
- [ ] Between services: nothing to do. The next service starts on its own.
- [ ] After service: **Stop**.

## Where things live

| What | Where |
|---|---|
| Settings | `~/Library/Application Support/PCOSync/config.json` |
| PCO credentials | `~/Library/Application Support/PCOSync/credentials.json` (mode 600) |
| Log | `~/Library/Logs/PCOSync/pcosync.log` (rotated at 2 MB, 5 kept). Also in the dashboard's **Log** tab. |

Credentials are never logged. A filter redacts them if one ever slips into a message.

**Dashboard access:** by default the dashboard only answers on this Mac (127.0.0.1). To open it from another computer (e.g. the tech booth laptop), turn on **Allow other computers to open this dashboard** in Settings, set a password, and restart PCOSync. Then browse to `http://<this-mac's-ip>:8642`. The username can be anything. Only do this on a network you trust: it's plain HTTP.

## Development

The code is a Swift package:

- `Sources/PCOSyncCore`: the sync engine, matcher, Planning Center and ProPresenter clients, settings, log, and the web server, API and dashboard. It's plain Foundation and builds on Linux too.
- `Sources/PCOSync`: the app entry point and the macOS menu bar.
- `Tests/PCOSyncCoreTests`: engine, matcher, client, service and web API tests against in-memory fakes of both APIs.

```sh
swift test                 # all tests
swift build                # debug build
scripts/build-app.sh       # build/PCOSync.app
```

To try it with no ProPresenter or PCO, run the mock servers (`pip install httpx` first):
```sh
python3 tools/mock_servers.py                     # fake PCO on :8765, fake ProPresenter on :50001
# in another terminal:
PCO_BASE_URL=http://127.0.0.1:8765 swift run PCOSync --headless --data-dir /tmp/pcosync-dev
```
Open http://127.0.0.1:8642, enter any Application ID and Secret, set Plan to "Next upcoming plan in the service type", pick the "Sunday" service type, and turn off "Only move LIVE around service times" (the mock plan's times are in the past). Type item numbers into the mock-server terminal to "fire" ProPresenter cues. `live` shows fake LIVE and `grab` makes someone else take control.

`PCOSync --headless` runs without the menu bar (Ctrl-C to stop). `--data-dir DIR` keeps settings and logs in DIR. `--port N` changes the dashboard port.

### Legacy Python CLI

The original Python command-line tool is still in `pcosync/` (`pip install -e . && python -m pcosync --help`). It reads `config.toml` (see `config.example.toml`) and the `PCO_APP_ID` / `PCO_SECRET` environment variables. It's kept as a fallback while the app is proven. The mock servers in `tools/` and the Python tests use it.
