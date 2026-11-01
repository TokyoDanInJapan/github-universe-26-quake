# Quake for the GitHub Universe 2026 badge

`setup-quake.sh` builds Quake for the badge and flashes it. It is based on
[zenodante/RP2350-Quake](https://github.com/zenodante/RP2350-Quake), with the patches in `patches/`
for the badge's pins, buttons, motion sensor and screen.

## Usage

```bash
./setup-quake.sh
```

The script:

1. Installs the build tools. It shows the command and asks first. It supports Arch, Debian/Ubuntu, Fedora and macOS.
2. Gets the Pico SDK and picotool. It uses the installed ones if they are version 2.x, or else it downloads and builds them.
3. Clones RP2350-Quake at a fixed commit and applies the badge patches.
4. Asks where your Quake files are. It looks in the Steam folder first. Use `pak0.pak` from the shareware release or the original `id1` folder. The 2021 re-release `pak0.pak` does not work.
5. Builds the game program and the game data.
6. Backs up all 16 MB of the badge's flash and checks the backup against the badge.
7. Flashes Quake to the badge.

Everything goes in `~/quake-badge` unless you give `--workdir`. Backups go in `~/quake-badge/backups`. The script never overwrites a backup.

## Options

| Option | Effect |
| --- | --- |
| `--pak PATH` | Use this `pak0.pak` or Quake folder. The script does not ask. |
| `--build-only` | Build, but do not touch the badge. |
| `--firmware-only` | Flash only the game program, not the 16 MB of game data. Use this after code changes. |
| `--backup-only` | Only back up the badge. |
| `--skip-backup` | Flash without making a backup first. |
| `--restore FILE` | Flash a backup back to the badge. |
| `--no-install` | Do not install packages. |
| `-y` | Do not ask for confirmation. |

## Restore the original badge software

```bash
./setup-quake.sh --restore ~/quake-badge/backups/<backup>.bin
```

## Controls

| Input | In game | In menus |
| --- | --- | --- |
| Tilt forward / back | Walk | - |
| Tilt left / right | Turn | - |
| DOWN | Fire | Down |
| UP | Jump | Up |
| LEFT / RIGHT | Strafe | Left / Right |
| SELECT | Next weapon. Hold it to open the menu. | Enter. Hold it to close the menu. |
| HOME | Menu. Hold it for 2 s to sleep. | Back. Hold it for 2 s to sleep. |

The badge starts at the main menu, with the demos playing behind it. When a game starts, and each time the menu closes, the game pauses. Hold the badge comfortably and press SELECT. That position becomes level for tilt.

To sleep, hold HOME for 2 seconds. The screen and the motion sensor turn off, and the game stops where it is. Press any front button to wake the badge. That press does nothing in the game. If a game is in progress, you set the tilt level again. Sleep keeps the badge powered, so it uses more battery than turning it off. The rear RESET button restarts the badge in hardware, so it cannot be used for sleep.

The picture is rotated 180 degrees. To change this, set `BADGE_SCREEN_ROTATED` to 0 in `platform/rp2350/qservice.h`. The tilt, strafe and menu directions change with it.

## Notes

- The badge has no speaker, so there is no sound.
- To put the badge in bootloader mode by hand, hold BOOT, press and release RESET, then release BOOT.
- On Linux, reading the badge's USB serial console needs membership of the `uucp` group (Arch) or the `dialout` group (Debian/Ubuntu).

## Credits and licence

This project builds on the work of others:

- [zenodante/RP2350-Quake](https://github.com/zenodante/RP2350-Quake): the RP2350 port of Quake that this project patches. GPL-3.0.
- [next-hack/MG24Quake](https://github.com/next-hack/MG24Quake): the low-memory Quake engine that RP2350-Quake is based on.
- id Software: the original Quake engine source, released under GPL-2.0-or-later.
- [Raspberry Pi Pico SDK](https://github.com/raspberrypi/pico-sdk) and [picotool](https://github.com/raspberrypi/picotool): BSD-3-Clause.
- Pimoroni: the badge hardware, a custom Tufty 2350 made for GitHub Universe.

The patches in `patches/` modify RP2350-Quake, so they are under the same GPL-3.0 licence. See [LICENSE](LICENSE). Each patch header gives its date and a description of the change. The setup script and this README are also under GPL-3.0.

Quake game data is not included. It belongs to id Software and is not covered by the GPL. Supply your own `pak0.pak` from the shareware release or a copy of Quake that you own. Do not share the converted game data, or badge backups made while Quake is installed, because they contain the game data.

Quake is a trademark of ZeniMax Media. This project is not affiliated with or endorsed by id Software, ZeniMax, GitHub or Pimoroni.
