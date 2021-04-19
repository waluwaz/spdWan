# spdWAN
## v0.0.1
spdWan is a hack based on spdMerlin. It might offer most of the same features except that it only supports the WAN interface
and it supports multiple Ookla servers for the same interface (i.e. the WAN interface). Most references to "interface" should be understood as references to one among several "probes" and all probes apply to the WAN interface. Different probes might be related to different preferred servers. All results from a specific probe will be grouped in a dedicated file. The files/probes happen to have names that usually refer to interfaces, even though in this case the only targetted interface is WAN.
The coding is brutal from a person with close to zero experience in shell scripting. It should not start a nuclear war. However, it might impact one of your most critical piece of hardware. Feel free to use as a source of laughing, and/or inspiration of what to do or what NOT to do. I do not recommend you run this as is , unless you  really feel adventurous...
I also share to clarify if there is interest in the "scope" of the script among users and/or scripters.


# spdMerlin
[![Codacy Badge](https://api.codacy.com/project/badge/Grade/1e0da6475e3047d59b35e258a18b78fc)](https://www.codacy.com/app/jackyaz/spdMerlin?utm_source=github.com&amp;utm_medium=referral&amp;utm_content=jackyaz/spdMerlin&amp;utm_campaign=Badge_Grade)
[![Build Status](https://travis-ci.com/jackyaz/spdMerlin.svg?branch=master)](https://travis-ci.com/jackyaz/spdMerlin)

## v4.2.1
### Updated on 2021-04-07
## About
spdMerlin is an internet speedtest and monitoring tool for AsusWRT Merlin with charts for daily, weekly and monthly summaries. It tracks download/upload bandwidth as well as latency, jitter and packet loss.

spdMerlin is free to use under the [GNU General Public License version 3](https://opensource.org/licenses/GPL-3.0) (GPL 3.0).

spdMerlin uses [Speedtest CLI](https://www.speedtest.net/apps/cli)

spdMerlin includes the required licenses, which must be accepted on first run of Speedtest CLI.

This script began as a user-friendly installer for a personal project developed by [JGrana](https://www.snbforums.com/members/jgrana.20663/)

A swap file is required, you can set one up easily by using amtm, which is built into the router.

### Supporting development
Love the script and want to support future development? Any and all donations gratefully received!

[**PayPal donation**](https://paypal.me/jackyaz21)

[**Buy me a coffee**](https://www.buymeacoffee.com/jackyaz)

## Supported firmware versions
You must be running firmware Merlin 384.15/384.13_4 or Fork 43E5 (or later) [Asuswrt-Merlin](https://asuswrt.lostrealm.ca/)

## Installation
Using your preferred SSH client/terminal, copy and paste the following command, then press Enter:

```sh
/usr/sbin/curl --retry 3 "https://raw.githubusercontent.com/jackyaz/spdMerlin/master/spdmerlin.sh" -o "/jffs/scripts/spdmerlin" && chmod 0755 /jffs/scripts/spdmerlin && /jffs/scripts/spdmerlin install
```

## Usage
### WebUI
spdMerlin can be configured via the WebUI, in the Addons section.

### Command Line
To launch the spdMerlin menu after installation, use:
```sh
spdmerlin
```

If this does not work, you will need to use the full path:
```sh
/jffs/scripts/spdmerlin
```

## Screenshots

![WebUI](https://puu.sh/HvYnR/d248031bb2.png)

![CLI](https://puu.sh/HvYrX/d7b6ee5840.png)

## Help
Please post about any issues and problems here: [spdMerlin on SNBForums](https://www.snbforums.com/forums/asuswrt-merlin-addons.60/?prefix_id=19)
