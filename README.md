# Olivera launcher

A small native macOS control panel for a local voice-guide server. One button
starts the whole chain — a llama.cpp server, a whisper.cpp server and the Python
service — and tells you when the headset can connect.

It was written for [l'Olivera](https://www.uv.es/), a VR reconstruction of the
Casa de Comedias de l'Olivera (València, 16th c.). The VR application runs on a
Windows PC; the voice guide runs on a Mac on the same network. This app exists
so that starting the Mac side is a double click instead of three terminals.

The guide server itself is a separate project. **This repository is only the
launcher**, and it is deliberately structured so that a Windows version is a
port of one file rather than a rewrite.

## What it does

- **Starts and stops the whole chain** with one button, and leaves no orphans
  behind. A stranded `llama-server` holds ~4 GB until you reboot.
- **Shows the address** to type into the Unity client, with a copy button.
- **Says who else answers on the network.** The Unity client discovers the
  server by UDP broadcast and takes *whoever replies first*. With two servers up
  — the Mac and the PC, which is the normal situation while comparing them — the
  choice is not deterministic, and you end up measuring one machine while
  believing you are measuring the other.
- **Says how much memory is left.** The chain needs about 5 GB. When memory runs
  out the service is paged out entirely — `rss` at zero, CPU at zero — and the
  system does not bring it back. From the outside that is indistinguishable from
  a hang.
- **Shows a real progress bar**, because the phases the server announces are
  known and ordered, so the app can say *how much* is left rather than only that
  something is happening.
- **Runs a quick self-test**: one voice command and one question, without the
  headset. The command must come back as an *action*; if it comes back as words,
  the server is running older code than the checkout.

## Build

Requires macOS 13+ and the Swift toolchain that ships with Xcode. No Xcode
project, no package manager: five source files and an `Info.plist`.

```bash
./build.sh          # produces build/Olivera.app
./build.sh --apri   # …and opens it
```

The app is signed ad-hoc, not notarised. On first launch macOS will ask for
confirmation: right-click the app, *Open*, then *Open* again.

## The contract with the server

The app knows two things about the voice pipeline, and nothing else.

**1. It starts it with one command, the same on every operating system:**

```
<python> -m olivera.launch --port 8765 [--no-discovery]
```

**2. It reads the phase from lines the launcher prints on stdout:**

```
@@olivera {"fase": "llm", "testo": "carico qwen3:4b-instruct-2507-q4_K_M con llama.cpp"}
@@olivera {"fase": "pronta", "testo": "in ascolto su 0.0.0.0:8765", "porta": 8765}
```

Five phases, in order: `avvio`, `llm`, `modelli`, `scaldo`, `pronta` — plus
`errore`. The prefix cannot occur by accident in a llama.cpp or uvicorn log, and
the object can grow new fields without breaking readers. An earlier version
searched for sentences *inside* the log text; that works until somebody rewrites
a message, and then the progress bar stops with nobody connecting the two facts.

Health and models come from `GET /health`. Two more commands back the network
probe and the self-test buttons:

```
<python> -m olivera.tools.chi_risponde --json
<python> scripts/prova_rapida.py --url ws://127.0.0.1:8765/ws --json
```

The differences between machines — llama.cpp or Ollama, HuggingFace's symlink
problem on Windows, the VRAM keep-alive — live inside `olivera/launch.py` on the
server side, where they can be read next to each other. They are not the app's
business.

## Porting to Windows

The platform coupling is isolated in **`Sources/Piattaforma.swift`**: a protocol
with six members, and under each one a comment saying what the Windows
equivalent is. Nothing else in the app names an operating system.

| protocol member | macOS | Windows |
|---|---|---|
| `comando(_:)` | `/bin/zsh -lc` | `powershell.exe -NoProfile -Command` |
| `python` | `./.venv/bin/python` | `.venv\Scripts\python.exe` |
| `indirizzoLocale()` | `getifaddrs` | `GetAdaptersAddresses` |
| `memoriaLibera(radice:)` | `vm_stat` + `hw.memsize` | `GlobalMemoryStatusEx` |
| `requisiti(radice:)` | `command -v`, `~/.cache` | `Get-Command`, `%LOCALAPPDATA%` |
| `cartellaPesi` | `~/.cache/olivera` | `%LOCALAPPDATA%\olivera` |

The command that starts the service is built once in a protocol extension and is
identical on both systems, so a port does not get to invent its own.

Two choices worth keeping whatever the UI framework:

- **Treat a death during startup as a failure even when the exit code is zero.**
  The first version of this app went through a shell script whose exit trap reset
  the return code, so a script that died on its second line presented itself as a
  clean exit — and the app simply went back to "off", as if the button had not
  been pressed. That cost an hour.
- **Give up loudly.** The launcher watches its own progress: after 45 s on the
  same phase it says which one, and after 150 s it stops waiting, closes its
  children and exits non-zero. An unbounded wait is the most expensive failure to
  explain, because the person watching cannot tell a slow start from a dead one.

If the Windows UI is C# rather than Swift — WinUI 3, WPF, Avalonia — the Swift
protocol still earns its keep as the specification: it is the complete list of
what a host has to provide, and it is six items long.

## Notes for whoever reads the code

Comments are in Italian, because the project they belong to is. They are also
denser than usual in the places where something went wrong: each long comment
marks a specific failure that was diagnosed once, and is there so it does not
have to be diagnosed twice.

## Licence

MIT — see [LICENSE](LICENSE).
