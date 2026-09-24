<div align="center">

<img src="assets/logo/zimacs-256.png" alt="Zimacs" width="120">

# Zimacs

A small, fast text editor written in Zig.

</div>

## Install

Linux:

```sh
curl -fsSL https://raw.githubusercontent.com/IWhitebird/Zimacs/master/scripts/install.sh | sh
```

Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/IWhitebird/Zimacs/master/scripts/install.ps1 | iex
```

No admin rights needed. Or download it from the
[releases page](https://github.com/IWhitebird/Zimacs/releases/latest).

Zimacs updates itself. Updates are signed, and one that fails the check is
refused. Set `auto_update = false` in the settings to turn this off.

## Settings

`Help → Edit Settings`, or `Ctrl+,`. The file lives in `~/.config/zimacs`
on Linux and `%APPDATA%\zimacs` on Windows.

## Build

Needs [Zig 0.16.0](https://ziglang.org/download/).

```sh
zig build run
zig build test
```

## Licence

MIT. Bundles JetBrains Mono and a subset of Noto Emoji, both under the
SIL Open Font License 1.1. The website shows the Zig logo, under CC BY-SA 4.0.
