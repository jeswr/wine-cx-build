# wine-cx-build

Builds Wine for macOS from CodeWeavers' published CrossOver open-source sources (LGPL) on GitHub's macOS runners, for personal use with DXMT, and provides a launcher for LEGO Star Wars: The Skywalker Saga on an Apple silicon Mac.

This repository contains build scripts only; it does not contain CrossOver application code or Apple's D3DMetal.

## What a release contains

- Wine built from the CrossOver sources (version pinned in `sources.lock`), 32-bit and 64-bit Windows parts.
- DXMT in place of Wine's own Direct3D 10/11. Wine's copies are kept in `orig-dlls/`.
- `lib/`: the Homebrew builds of FreeType, GnuTLS and SDL2 (with SDL3, which it now sits on) and their dependencies. Vulkan (MoltenVK) is left out: nothing here uses it, and it aborted on the build runner. Wine loads these by name at run time, so it must be started with `DYLD_FALLBACK_LIBRARY_PATH=<build>/lib:/usr/lib`.
- `manifest.env`: the tag, file name and checksum, which the launcher reads.

Run the "Build CrossOver Wine (macOS)" workflow from the Actions tab. A plain build from `main` becomes the latest release. Patched builds, builds from other branches and builds of a newly found CrossOver version are published as pre-releases. A weekly workflow checks for a new CrossOver source version.

## Playing

First time, in Terminal (quit CrossOver and Steam first):

```
mkdir -p ~/Games/skywalker && curl -fsSL https://raw.githubusercontent.com/jeswr/wine-cx-build/main/scripts/skywalker.sh -o ~/Games/skywalker/skywalker.sh && bash ~/Games/skywalker/skywalker.sh install
```

This downloads the latest build, copies the CrossOver "Steam" bottle to `~/Games/skywalker-cx` (the original is only read) and creates "Skywalker Saga" in `~/Applications`. After that, open the app. Each launch backs up the save files to `~/Games/SkywalkerSaga-saves`, starts Steam and the game, and shuts Wine down when the game exits. Wine is held to a few hundred processes, so a Wine that goes wrong cannot fill the Mac's process table.

| Command | What it does |
| --- | --- |
| `skywalker.sh steam [options]` | Opens Steam's window, to sign in or change settings. Extra options go to Steam, for example `-cef-disable-gpu` |
| `skywalker.sh bench <label>` | Plays with the frame counter on and prints average fps and the slowest 1% afterwards |
| `skywalker.sh update` / `rollback` | Installs the latest build / returns to the previous one |
| `skywalker.sh doctor` | Shows what is installed and what is missing |
| `skywalker.sh wine <args>` | Runs any Wine program with the launcher's settings, for troubleshooting |
| `skywalker.sh windows` | Lists the windows Wine has on screen, to tell "nothing is shown" from "hidden behind something" |
| `skywalker.sh graphics split\|dxmt\|wine\|d3dmetal` | `split` (the default) gives DXMT to the game only and leaves Steam on Wine's own Direct3D, because DXMT cannot draw Steam's windows; `dxmt` or `wine` uses one of them for everything; `d3dmetal` uses Apple's D3DMetal for everything, taken from your own copy of Apple's Game Porting Toolkit (see below). A newly installed build keeps the choice of the one before it |
| `skywalker.sh stop` | Shuts down Steam and Wine, and ends any Wine process left behind |
| `skywalker.sh display keep\|show\|off` | `keep` notes the game's screen and window settings as they are now; before every start the launcher puts them back if they have changed, after a copy of the settings file has gone to `~/Games/skywalker/settings-backups`. The game rewrites these settings by itself when an external monitor is plugged in or out, and then keeps the wrong size. Only the screen and window lines are touched. `off` stops it |
| `skywalker.sh prewarm [minutes]` | Starts Steam now, without a window and without the game. The next `run` then skips Steam's own start, which is most of the wait. Steam closes again after `PREWARM_MINUTES` (120; 0 = stays open) if the game is not played |
| `skywalker.sh autostart on\|off` | `on` makes macOS run `prewarm` at every log-in (a launch agent in your own Library, no administrator rights), so the first start of the day is already a quick one. Off unless you switch it on |
| `skywalker.sh cpu [seconds]` | Measures how much processor time Wine's programs use over the given time. With Steam open and no game, this is what keeping Steam open costs |
| `skywalker.sh timeline` | Shows how long the last start took (Steam, Steam's browser part, the game) with the matching lines of Steam's logs |

Steam's own start is most of the wait before the game appears, so the launcher shortens it in two ways. It tells Steam not to start its graphics process (`STEAM_GPU=0`), which cannot work under this Wine and which Steam otherwise retries several times before giving up. And it leaves Steam open for 30 minutes after the game ends (`KEEP_STEAM_MINUTES=30`), so that the next start within that time skips Steam's start altogether; `skywalker.sh stop` closes it at once, and `KEEP_STEAM_MINUTES=0` closes it with the game. The first start after logging in still has to wait for Steam; `skywalker.sh prewarm` or `skywalker.sh autostart on` moves that wait to a time when you are not waiting for it, at the price of Steam running in the background (`skywalker.sh cpu 60` shows how much it uses).

Settings are in `~/Games/skywalker/config.env` (upscaling, frame cap, AVX, frame counter, the two above). `SKY_UPSCALE=1 skywalker.sh bench upscaled` overrides one for a single run.

### Apple's D3DMetal

D3DMetal is Apple's own Direct3D layer. It is not part of this repository or its releases and the launcher cannot download it. If you have Apple's Game Porting Toolkit, put it in `~/Games/gptk` (the app itself, or its `lib` folder; `GPTK_DIR` in `config.env` can name another folder) and run `skywalker.sh graphics d3dmetal`. The launcher copies Apple's Direct3D 11/12 and DXGI files, `libd3dshared.dylib` and `D3DMetal.framework` from there into the build in use and keeps what they replace; `skywalker.sh graphics split` takes them out again. A first install uses D3DMetal by itself when Apple's files are there, and an update keeps whatever the build before it used.

`scripts/try-on-mac.sh` is the earlier one-off test script and is kept for reference.
