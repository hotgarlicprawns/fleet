# fleet — Licensing

fleet is made of two parts with different licenses.

---

## 1. The Claude Code plugin (`plugin/`) — MIT

Copyright (c) 2026 bishesh

Permission is hereby granted, free of charge, to any person obtaining a copy
of this plugin and associated documentation files (the "Plugin"), to deal
in the Plugin without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Plugin, and to permit persons to whom the Plugin is furnished
to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Plugin.

THE PLUGIN IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE PLUGIN OR THE USE OR OTHER DEALINGS IN THE
PLUGIN.

---

## 2. The fleet CLI and Fleet.app (`bin/`, `hud/`, `gui/`, `app/`) — End User License Agreement

Copyright (c) 2026 bishesh. All rights reserved.

### Grant

On purchase of a valid license key, you are granted a non-exclusive,
non-transferable license to install and use the fleet CLI and Fleet.app ("the Software")
on the number of devices permitted by your license tier, for your own
personal or internal business use.

A 14-day evaluation period is provided without a license key. After it ends,
unlicensed use is limited to the Free tier features described in the README.

### You may

- Use the Software on your licensed devices.
- Read and modify the source for your own use and debugging.
- Deactivate a device (`fleet license deactivate`) to free a seat.

### You may not

- Redistribute, resell, sublicense, rent, or publish the Software or your
  license key.
- Remove or circumvent the license check, or share a key to exceed your
  seat count.
- Use the Software to build a competing product.

### Data

The Software runs entirely on your machine. License keys are verified
against Dodo Payments' public license endpoints. Session cost and context
data written under `~/.config/fleet/` never leaves your device. No
telemetry is collected without a separate, clearly labelled opt-in.

### Warranty & liability

THE SOFTWARE IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND. THE AUTHOR
IS NOT LIABLE FOR ANY DAMAGES ARISING FROM ITS USE, INCLUDING BUT NOT
LIMITED TO LOST WORK, LOST REVENUE, OR MACHINE STATE (SLEEP, DISPLAY, OR
EDITOR SETTINGS). YOU ARE RESPONSIBLE FOR REVIEWING WHAT `fleet tune`,
`fleet hud install`, and `fleet display` change on your system; each is
reversible and documented.

### Refunds

30-day money-back guarantee, no questions asked. Email the address on the
checkout receipt.

### Termination

This license ends if you breach its terms. On termination you must stop
using the Software and delete your copies.
