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
| `skywalker.sh graphics split\|dxmt\|wine` | `split` (the default) gives DXMT to the game only and leaves Steam on Wine's own Direct3D, because DXMT cannot draw Steam's windows; `dxmt` or `wine` uses one of them for everything |
| `skywalker.sh stop` | Shuts down Steam and Wine, and ends any Wine process left behind |

Settings are in `~/Games/skywalker/config.env` (upscaling, frame cap, AVX, frame counter). `SKY_UPSCALE=1 skywalker.sh bench upscaled` overrides one for a single run.

`scripts/try-on-mac.sh` is the earlier one-off test script and is kept for reference.
