# Olivera launcher

A small native macOS control panel for a local voice-guide server. One button
starts the whole chain — a llama.cpp server, a whisper.cpp server and the Python
service — and tells you when the headset can connect.

It was written for [l'Olivera](https://www.uv.es/), a VR reconstruction of the
Casa de Comedias de l'Olivera (València, 16th c.). The VR application runs on a
Windows PC; the voice guide runs on a Mac on the same network. This app exists
so that starting the Mac side is a double click instead of three terminals.

The guide server itself is a separate project. **This repository is only the
launcher.**

## What it does

- **Starts and stops the whole chain** with one button, and leaves no orphans
  behind. A stranded `llama-server` holds ~4 GB until you reboot.
- **Shows the address** to type into the Unity client, with a copy button.
- **Says who else answers on the network.** The Unity client discovers the
  server by UDP broadcast and takes *whoever replies first*. With two servers up
  — the Mac and the PC, which is the normal situation while comparing them — the
  choice is not deterministic, and you end up measuring one machine while
  believing you are measuring the other. The app makes that visible; the server
  side has a `--no-discovery` flag for the one that should stay quiet.
- **Says how much memory is left.** On a 16 GB machine the chain needs about
  5 GB. When memory runs out the service is paged out entirely — `rss` at zero,
  CPU at zero — and the system does not bring it back. From the outside that is
  indistinguishable from a hang. Knowing it early saves an afternoon.
- **Runs a quick self-test**: one voice command and one question, without the
  headset. The command must come back as an *action*; if it comes back as words,
  the server is running older code than the checkout.

## Build

Requires macOS 13+ and the Swift toolchain that ships with Xcode. No Xcode
project, no package manager: three source files and an `Info.plist`.

```bash
./build.sh          # produces build/Olivera.app
./build.sh --apri   # …and opens it
```

The app is signed ad-hoc, not notarised. On first launch macOS will ask for
confirmation: right-click the app, *Open*, then *Open* again.

## How it talks to the server

The app deliberately knows nothing about the voice pipeline. The contract is
three things, and that is the whole of it:

| | |
|---|---|
| `./scripts/serve_mac.sh` | started as a child process, with `OLIVERA_*` variables in the environment |
| its standard output | parsed for four phrases to drive the progress label |
| `GET /health` | polled every 2 s for the loaded models |

Plus two helper commands from the server project, used by the network probe and
the self-test buttons:

```
python -m olivera.tools.chi_risponde --json
python scripts/prova_rapida.py --url ws://127.0.0.1:8765/ws --json
```

The day the pipeline changes, the script changes and the app keeps working
without knowing what changed. This is also why the probes are Python processes
of the server project instead of being rewritten in Swift: there is one source
of truth about how to talk to the server.

Environment variables passed to the script:

| variable | values |
|---|---|
| `OLIVERA_TTS` | `kokoro`, `say`, `qwen-mps` |
| `OLIVERA_QUANT` | `q4_K_M`, `q8_0` |
| `OLIVERA_PORT` | default `8765` |
| `OLIVERA_DISCOVERY` | `1` / `0` |

The app builds a **clean** environment (only `HOME`, `USER`, `SHELL`, `TMPDIR`,
`LANG`, `PATH`) rather than inheriting its parent's. Inheriting looks prudent
and is not: depending on whether the app is opened from Finder, from the Dock or
from a terminal, the child gets different variables and the service behaves
differently for no visible reason.

## Porting to Windows

The three files split cleanly, and only one of them is platform-specific.

- `OliveraApp.swift` and `Finestra.swift` are the app shell and the view. On
  Windows the natural equivalents are WinUI 3 / WPF, or Avalonia if you want one
  codebase for both.
- `Motore.swift` is where all the platform coupling lives, and it is small:
  - launching `/bin/zsh -lc` → `powershell.exe -Command` (and a `serve_win.ps1`
    beside `serve_mac.sh`; the server project already ships `start_server.ps1`)
  - `getifaddrs` for the LAN address → `GetAdaptersAddresses`
  - `vm_stat` + `hw.memsize` for memory → `GlobalMemoryStatusEx`
  - process termination: `Process.terminate()` sends `SIGTERM` and the shell
    script traps it. On Windows there is no equivalent, so the stop path has to
    go through a job object or a PID file.
- Everything else — the health polling, the log parsing, the discovery probe —
  is plain HTTP and JSON and moves over unchanged.

The one thing worth keeping whatever the platform: **treat a death during
startup as a failure even when the exit code is zero.** The shell script has an
exit trap that resets the return code, so a script that dies on its second line
can present itself as a clean exit. That cost an hour once.

## Notes for whoever reads the code

Comments are in Italian, because the project they belong to is. They are also
denser than usual in the places where something went wrong: each of the long
comments in `Motore.swift` marks a specific failure that was diagnosed once, and
is there so it does not have to be diagnosed twice.

## Licence

MIT — see [LICENSE](LICENSE).
