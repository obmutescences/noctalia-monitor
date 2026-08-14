# Noctalia System Monitor

A system monitoring plugin for [Noctalia]: a compact CPU/RAM bar widget plus a
per-process panel covering CPU, memory, GPU, network and disk activity.

![plugin](https://img.shields.io/badge/plugin_api-12-blue)
![license](https://img.shields.io/badge/license-MIT-green)

## Features

- **Bar widget** — shows live CPU and RAM usage percentages with icons; click
  it to toggle the process panel. Works in both horizontal and vertical bars.
- **Process panel** — five tabs, each showing the **top 20 processes** sorted
  by the tab's metric, with name, PID and a per-metric column:

  | Tab | Column | Format |
  | --- | --- | --- |
  | CPU | usage % with progress bar | `42%` |
  | Memory | usage % with progress bar | `512 MB · 12%` |
  | GPU | VRAM usage with progress bar | `2.4 GB · 15%` |
  | Network | down / up rates | `1.2 MB/s` |
  | Disk | write rate | `350 KB/s` |

- **System-wide summary row** — CPU %, RAM (used + %), GPU (VRAM + %) and disk
  usage % at the top of the panel.
- **Metric coloring** — values are tinted by severity: `primary` at rest,
  `warning` from 50%, `error` from 80%, on every tab.
- **Theme-aware UI** — built from Noctalia palette tokens, so the panel follows
  the host's current theme automatically.
- **Configurable sampling** — refresh interval adjustable from 1 to 60 seconds.
- **Customizable colors** — widget text and icon colors are user-configurable.
- **Localized settings** — English localization bundled; structure ready for
  more locales.

## Requirements

- Linux (data is read from `/proc`, so other platforms are not supported).
- `iproute2` (`ss`) for per-process network stats.
- `getconf`, `awk`, `grep`, `sed` (standard coreutils / POSIX tools).
- An AMD GPU with the `amdgpu` driver (DRM fdinfo) for GPU VRAM stats — the GPU
  tab is skipped gracefully when no GPU data is available.

## Installation

Clone or copy this repository as a plugin directory for your Noctalia plugins
folder:

```sh
git clone https://github.com/obmutescences/noctalia-monitor.git
```

Then enable **System Monitor** in Noctalia. A CPU/RAM bar appears in the bar;
click it (or use its context menu) to open the process panel.

## Configuration

| Setting | Default | Description |
| --- | --- | --- |
| Refresh Interval (s) | `2` | How often process data is sampled and refreshed (1–60 s) |
| Text Color | theme default | Color of the widget's CPU/RAM percentage text |
| Icon Color | falls back to Text Color | Color of the widget's icons |

## How it works

The plugin ships three components (see `plugin.toml`):

- **`widget.luau`** — the bar widget. Polls `noctalia.systemStats()` every
  2 seconds and renders CPU/RAM percentages; `onClick` toggles the panel.
- **`service.luau`** — the sampler. Every refresh interval it runs three
  async shell pipelines and publishes the results to `noctalia.state.procs` as
  five pre-sorted lists (`cpu`, `mem`, `gpu`, `net`, `disk`, top 20 each):
  - `getconf PAGESIZE` + `awk /proc/meminfo` + a loop over `/proc/[pid]/stat`,
    `/statm` and `/io` → CPU ticks (`utime`+`stime`), RSS pages, `write_bytes`.
  - `ss -ntinp` → per-process TCP `bytes_acked` / `bytes_received` counters.
  - a `grep` + `awk` pass over `/proc/[pid]/fdinfo` → summed `drm-memory-vram`
    / `drm-memory-gtt` per process (identical cumulative values across fds are
    deduplicated, since several fds of one process usually pin the same
    buffers).
  - Deltas between consecutive samples produce CPU %, memory % and write /
    network rates (Linux `USER_HZ` = 100, so CPU % = tick delta / elapsed).
- **`panel.luau`** — the process panel. Renders the system summary, the tab
  bar, and the sorted process list; re-renders immediately whenever the
  service publishes new data (with the refresh interval as a backup timer).

All sampling is **local** — nothing leaves your machine.

## License

[MIT](LICENSE)
