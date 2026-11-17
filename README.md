# cec-sidecar

Make your TV remote reliably control a Linux PC over HDMI-CEC, including right after the TV powers on.

This is a small companion to Valve's [`cecd`](https://gitlab.steamos.cloud/holo/linux-cec) (from the linux-cec project). It fills in the CEC replies that `cecd` doesn't send, or doesn't send fast enough, when it runs with an external USB CEC adapter such as the Pulse-Eight.

It was built and tested on **Bazzite with an LG G1 (webOS) and a Pulse-Eight USB-CEC adapter**, controlling [Plezy](https://github.com/edde746/plezy). The diagnosis below should still be a useful starting point for other TVs, adapters and distros.

## The symptom

- The remote controls the PC fine **after you manually re-select the PC's HDMI input**.
- When the TV powers on and lands on the PC's input by itself, **remote keys don't come through**. The TV may also fall back to its home screen.

## Why it happens

TVs (LG in particular) only forward remote keys to a device that:

1. has announced itself as the **Active Source** for the input being shown, and
2. answers the TV's **Give Device Power Status** polls quickly (CEC expects a reply within about a second).

With a USB adapter, `cecd` fails on both counts:

- It tries to correlate the CEC adapter with a DRM connector's EDID. With a USB adapter that fails (`Message handling failed: No such file or directory` / `Failed to parse EDID`), so it never answers **Request Active Source** or **Give Device Power Status**.
- It ignores the TV's standby, so after the TV comes back it still thinks it is active and never re-announces itself.
- While the TV powers on, `cecd` stalls for seconds per message. Replying via its D-Bus API (`SendRawMessage`) or reacting to its `ReceivedMessage` signal was 2–6 s late, far too late for the TV.
- When the TV powers on, the PC's HDMI output reconnects. `cecd` sees that DRM hotplug and **reconfigures the adapter from scratch** (OSD name, vendor ID, logical address), even when nothing changed. Pinning `physical_address` in the config doesn't prevent it. While that runs, the kernel holds every transmit. With a Pulse-Eight, which is slow and serial, replies queued behind it go out 2–4 s late or fail with `MAX_RETRIES|ABORTED`. The kernel may also log `message queue is full`.

Here's what the TV does at power-on when nothing answers, captured with cecd at `RUST_LOG=debug`:

```
TV → all : Report Power Status: On
TV → all : Request Active Source          ← nobody answers
TV → PC  : Give Device Power Status  ×3–5 ← nobody answers
TV → all : Routing Change → 1.0.0.0, Set Stream Path 1.0.0.0
TV → all : Active Source 0.0.0.0          ← TV gives up and takes the input back
```

## What the helper does

`cec-sidecar` opens the CEC device **directly** (raw ioctls, no D-Bus) as an additional non-exclusive follower alongside `cecd`. It:

- replies to **Give Device Power Status** with **On**;
- replies to **Request Active Source** with **Active Source** + **Menu Status: activated**, *only if this PC was the last thing on screen*;
- announces **Active Source** when the TV sends **Routing Change** or **Set Stream Path** to the PC's physical address;
- tracks every device's **Active Source** messages, so it won't steal the screen after you used another device. The last active path is persisted in `~/.local/state/cec-sidecar/last_path`.

- **recovers when the power-on race is lost.** If the TV declares *itself* active source (`82 00 00`, i.e. shows its home screen) within 30 s of powering on, and the PC was the last input, the helper waits 2 s for the bus to settle. It then sends **Image View On** + **Active Source** (one-touch play) to pull the TV back to the PC, up to 3 times. Choosing another device in that window cancels recovery, and a takeover after the window (e.g. you pressed Home) is left alone.

Key handling is left entirely to `cecd`.

When the instant replies win the race, the TV goes straight to the PC on power-on, sometimes before its own home screen appears. When they lose (with a Pulse-Eight that's roughly half the time, depending on how the bus traffic lines up), recovery kicks in and you see the TV home screen briefly before it switches to the PC. Either way, the remote works without re-selecting the input.

Dependencies: Python 3 only (standard library). It runs as your user. Access to `/dev/cec*` normally comes from a `uaccess` udev rule.

## Setup

### 1. Get `cecd` running against your adapter

**Bazzite:**

```sh
ujust cec-mode native
```

This attaches the Pulse-Eight to the kernel CEC subsystem via `inputattach` (giving you `/dev/cec0`) and sets up `cecd`.

> **Gotcha:** if SteamOS Manager isn't installed, the recipe's `systemctl --user enable cecd steamos-manager-configure-cecd` fails as a whole (errors are hidden), so **cecd isn't enabled** and stops working after a reboot. `install.sh` enables it for you, or run `systemctl --user enable cecd`.

**Other distros:** you need a kernel CEC device (`/dev/cecN`): native GPU CEC, or a USB adapter attached with `inputattach --pulse8-cec` (see the kernel's [CEC admin guide](https://docs.kernel.org/admin-guide/media/cec.html) and Valve's [inputattach-cec-units](https://gitlab.steamos.cloud/holo/inputattach-cec-units)). Then run `cecd` as a user service.

### 2. Install the helper

```sh
./install.sh                     # helper + service, enables cecd
./install.sh --with-cecd-config  # also installs examples/cecd/90-local.toml if you have none
```

If your device isn't `/dev/cec0`, pass it as an argument in the unit's `ExecStart`, or set `CEC_DEVICE`.

### 3. Optional cecd config

[`examples/cecd/90-local.toml`](examples/cecd/90-local.toml):

- `wake_tv = true`: normally set by SteamOS Manager. Without it, the TV doesn't wake when the PC resumes.
- A full `[mappings]` table. Overriding `mappings` **replaces all cecd defaults**, so the example restates them, with one change: **red → `KEY_COMPOSE`** (the keyboard Menu key, i.e. Flutter's `contextMenu`).

## Long-press doesn't work over CEC (and a workaround)

Many TVs, LG included, don't send a held button as a held key. Holding OK arrives as repeated short press/release pairs about 70 ms long, with the first repeat after roughly 420–560 ms. Apps that detect long-press as "key down for 500 ms" (Plezy, for one) never see one.

Faking the hold would mean delaying *every* OK press by about 650 ms, so the example config instead maps a spare colour button to the **Menu** key. Plezy, and many other TV-style apps, treat that as "open the context menu".

## Plezy notes

- **Settings → Controls → Video Player Navigation:** turn this on so up/down in the player navigate the controls instead of changing volume. It's only on by default when Plezy detects a TV platform.
- Back on the remote arrives as Esc and OK as Enter, both of which Plezy handles.

## Debugging

```sh
# CEC traffic as cecd sees it (no root needed):
busctl --user monitor com.steampowered.CecDaemon1

# cecd debug logs:
systemctl --user edit cecd    # add: [Service] Environment=RUST_LOG=debug
journalctl --user -u cecd -u cec-sidecar -f

# Bus topology:
cec-ctl -d /dev/cec0 -S

# Helper verbose mode: every TV message (with receive lag) and every transmit
# result (OK / NACK / MAX_RETRIES, with queue latency):
systemctl --user edit cec-sidecar   # add: [Service] Environment=CEC_VERBOSE=1
```

Things to look for in a failing power-on:
- `tx … after 3000ms`: the TX queue is backed up (see "Why it happens").
- `Attempting to set logical addresses` from cecd right after the TV powers on: the hotplug reconfigure.
- `rx 0f820000`: the TV gave up and took the input itself. With recovery you should then see `will reclaim` and `claimed active source (recovery #1)`.

`cec-ctl --monitor` needs root (`CAP_NET_ADMIN`). Reading the cecd uinput event device needs root or the `input` group.

## Tested with

| | |
|---|---|
| Distro | Bazzite (Fedora 45 base), kernel 7.3 |
| Adapter | Pulse-Eight USB-CEC (`pulse8-cec`, via inputattach) |
| TV | LG G1 (webOS) |
| cecd | 0.3.0 |
| Also on the bus | WiiM amp (audio system), PS5 |

Reports from other TVs and adapters are very welcome. Please include a `RUST_LOG=debug` cecd log of the TV powering on.

## License

MIT
