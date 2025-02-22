# spdWAN
## v0.0.2
spdWan is a hack based on spdMerlin v4.2.1. It might offer most of the same features except that it only supports the WAN interface
and it supports multiple Ookla servers for the same interface (i.e. the WAN interface). Most references to "interface" should be understood as references to one among several "probes" and all probes apply to the WAN interface. Different probes might be related to different preferred servers. All results from a specific probe will be grouped in a dedicated file. The files/probes happen to have names that usually refer to interfaces, even though in this case the only targetted interface is WAN.
The coding is brutal from a person with close to zero experience in shell scripting. It should not start a nuclear war. However, it might impact one of your most critical piece of hardware. Feel free to use as a source of laughing, and/or inspiration of what to do or what NOT to do. I do not recommend you run this as is , unless you  really feel adventurous...
I also share in order to clarify if there is interest in the "scope" of the script among users and/or scripters.

WARNING: When runnning in schedule mode, the script might run several probes but it will stop as soon as the download speed reaches a target minimum. This is based on the value defined as upper download limit for the AutoBW feature.


spdWan is free to use under the [GNU General Public License version 3](https://opensource.org/licenses/GPL-3.0) (GPL 3.0).

spdWan uses [Speedtest CLI](https://www.speedtest.net/apps/cli)

spdWan includes the required licenses, which must be accepted on first run of Speedtest CLI.

This script is just a weekend experiment. It is based on work by Jack Yaz and by [JGrana](https://www.snbforums.com/members/jgrana.20663/)

A swap file is required, you can set one up easily by using amtm, which is built into the router.

### Supporting development
Love the script ??? I don't take donations. However, the original work for spdMerlin by Jack Yaz deserves your donations.

[**PayPal donation**](https://paypal.me/jackyaz21)

[**Buy him a coffee**](https://www.buymeacoffee.com/jackyaz)

## Supported firmware versions
This is not supported in any way, whatever the version. It is more likely to run on Merlin 384.15/384.13_4 or Fork 43E5 (or later) [Asuswrt-Merlin](https://asuswrt.lostrealm.ca/)

## Installation
Using your preferred SSH client/terminal, copy and paste the following command, then press Enter:

```sh
/usr/sbin/curl --retry 3 "https://raw.githubusercontent.com/jackyaz/spdMerlin/master/spdmerlin.sh" -o "/jffs/scripts/spdmerlin" && chmod 0755 /jffs/scripts/spdmerlin && /jffs/scripts/spdmerlin install
```
Then, if you feel VERY lucky, replace that spdmerlin.sh by the spdmerlin.sh from this branch. Obviously, you have now "sabotaged" your spdMerlin
and replaced it with spdWan, which disguises itself in a spdMerlin file. spdWan is not designed to pruposefully harm your system.
In practice, it has the potential to harm it though :-)  It was only "tested" by its author on his own environment... 


## Usage
### WebUI
spdWan can be configured via the WebUI, in the Addons section.

### Command Line
To launch the spdWan menu after installation, use:
```sh
spdmerlin
```

If this does not work, you will need to use the full path:
```sh
/jffs/scripts/spdmerlin
```

## Screenshots
Well, I didn't change the WebUI, so spdMerlin screenshots still apply.


## Help
You're on your own... Unsupported weekend experiment...
