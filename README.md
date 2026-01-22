![SH1MMER (light)](/assets/sh1mmer_light_banner.png#gh-dark-mode-only)
![SH1MMER (dark)](/assets/sh1mmer_dark_banner.png#gh-light-mode-only)

### Shady Hardware 1nstrument Makes Machine Enrollment Retreat
_Website, source tree, and write-up for a ChromeOS™️ enrollment jailbreak_
***

## What is SH1MMER?

**SH1MMER** is an exploit found in the ChromeOS shim kernel that utilitzes modified RMA factory shims to gain code execution at recovery.
_For more info, check out the blog post/writeup [here](https://blog.coolelectronics.me/breaking-cros-2/)_.

#### How does it work?

RMA shims are a factory tool allowing certain authorization functions to be signed,
but only the KERNEL partitions are checked for signatures by the firmware.
We can edit the other partitions to our will as long as we remove the forced readonly bit on them.

## How do I use it?

> [!NOTE]
> [dl.sh1mmer.me](https://dl.sh1mmer.me) has been taken down, so you'll need to find a site rehosting the RMA shims alongside Chromebrew.

Here's how you do that.
First, you need to know your Chromebook's board. Go to `chrome://version` on your Chromebook and copy the word after `stable-channel`.
If `chrome://version` is blocked, you can search up your Chromebook's model name on [cros.download](https://cros.download/recovery)
and see what board it corresponds to. **DO NOT USE WITH A RECOVERY IMAGE FROM [cros.download](https://cros.download/recovery), IT WILL NOT WORK.**

If your board name is in the list below, great! Find the RAW RMA shim corresponding to your board online.
We can no longer provide raw RMA shims due to legal reasons. [**More information here**](https://discord.gg/egWXwEDWKP).

ambassador, banon, brask, brya, clapper, coral, corsola, cyan, dedede, edgar, elm, enguarde, fizz,
glimmer, grunt, hana, hatch, jacuzzi, kalista, kefka, kukui, lulu, nami, nissa, octopus, orco, puff,
pyro, reef, reks, relm, sand, sentry, snappy, stout, strongbad, tidus, trogdor, ultima, volteer, zork

If it's not, good luck. You'll have to try and call up your OEM and demand the files from them, which they are most unlikely to give to you.

***

### Building A Beautiful World Shim

Now you can start building. Type out all of these commands in the terminal.
You need to be on Linux or WSL2 and have the following packages installed: `git`, `wget`.
You may need to install additional packages, which the script will prompt you to do.

```
git clone https://github.com/MercuryWorkshop/sh1mmer
cd sh1mmer/wax
sudo bash wax.sh -i path/to/the/shim/you/downloaded.bin
```
This will build a beautiful world mini shim. If you want to add chromebrew, do the following:

```
git clone https://github.com/MercuryWorkshop/sh1mmer
cd sh1mmer/wax
wget "https://data.crosbreaker.dev/ChromeOS/chromebrew/chromebrew.tar.gz"
sudo bash wax.sh -i path/to/the/shim/you/downloaded.bin --chromebrew chromebrew.tar.gz -s 4G
```

> [!NOTE]
> If you want to build a devshim, replace `chromebrew.tar.gz` with `chromebrew-dev.tar.gz` and replace `-s 4G` with `-s 7G` in the wax command.
> Devshim builds will mount a much larger Chromebrew partition over `/usr/local`,
> allowing you to access a desktop environment and even Firefox from within SH1MMER.
> It's what allowed us to [run DOOM on a shim](https://github.com/CoolElectronics/blog/blob/master/src/content/blog/breaking/doom.jpg?raw=true).

When this finishes, the bin file in the path you provided will have been converted into a **SH1MMER** image.
*Note that this is a destructive operation, you will need to redownload a fresh shim to try again if it fails.*

After injecting, you may continue to the "[Booting Into A Shim](#booting-into-a-shim)" section.

***

### Building A Legacy Shim

Type out all of these commands in the terminal.

```
git clone https://github.com/MercuryWorkshop/sh1mmer
cd sh1mmer/wax
sudo bash wax.sh -i path/to/the/shim/you/downloaded.bin -p legacy
```

> [!NOTE]
> Legacy shims are easier to update and are recommended for advanced users and developers.

When this finishes, the bin file in the path you provided will have been converted into a **SH1MMER** image.
*Note that this is a destructive operation, you will need to redownload a fresh shim to try again if it fails.*

After injecting, you may continue to the "[Booting Into A Shim](#booting-into-a-shim)" section.

***

### Booting Into A Shim

Once you have injected your raw shim with SH1MMER, go into the Chromebook Recovery Utility, select the settings icon (⚙️), select `Use local image`, and then select your injected shim.
Alternatively, you can also use other flashers such as [Rufus](https://rufis.ie), [UNetbootin](https://unetbootin.github.io/), etc. On linux, `dd` is recommended.
*This may take up to 10 minutes, depending on the size of your shim and speed of your USB drive.*

On the Chromebook, press `ESC + Refresh (↻) + Power (⏻)` at the same time to enter the recovery screen, then press `CTRL + D` at the same time and press Enter.
This should enable Developer Mode or turn off OS Verification.
*This may be blocked by system policy, but that doesn't matter.*

Press `ESC + Refresh (↻) + Power (⏻)` at the same time again, then plug in your USB with SH1MMER and you should be booting into the Beautiful World GUI or a CLI screen.
From here, you can play around with the options and do what you want.

> [!NOTE]
> On `hana` and `elm` devices, you may need to re-enter recovery mode quickly after enabling developer mode
> (skipping the "OS verification is OFF" screen).

***
## Patch information and workarounds
<details>

### Patch for shims
The patches at [crrev/c/4160496](https://crrev.com/c/4160496) and [crrev/c/4160815](https://crrev.com/c/4160815) enable rootfs verification on RMA shims.

### R111 patch ("The Fog")
The patch at [crrev/c/4241653](https://crrev.com/c/4241653) prevents FWMP from being modified from RMA shims on Cr50 devices.
[crrev/c/4290246](https://crrev.com/c/4290246) also prevents the anti-rollback spaces from being modified from RMA shims when FWMP is present.  
*Note that the above 2 were released in r114 for Ti50 devices.*  
The patch at [crrev/c/4255465](https://crrev.com/c/4255465) forces an enrollment check when FWMP blocks developer mode.  
The patch at [crrev/c/4234303](https://crrev.com/c/4234303) attempts to prevent `hana` and `elm` devices from entering developer+recovery mode, but it is trivial to bypass.

Additionally, the kernel anti-rollback version was incremented in this version.
This means that once both the A and B partitions were at least at r111, the device could not be downgraded to older versions.

<details>
<summary>"The Fog" Bypass Details</summary>

> [!NOTE]
> It is recommended to use a different exploit instead if you're only affected by "_The Fog_" and nothing else.
> "_The Fog_" instructions are old, however that doesn't mean you can't try it _**if**_ you also wish to disable hardware write protection.

If your Chromebook has never updated to r114, unenrollment is still possible if you're willing to [disable hardware write protection](https://docs.mrchromebox.tech/docs/supported-devices.html).
On most devices, this will require you to take off the back of the Chromebook and unplug the battery, or bridge two jumper pins.
Further instructions are on [the website](https://sh1mmer.me/#fog).

#### "Unenrolling" with write protection enabled
If you aren't willing to take apart your Chromebook to unenroll, you can use an affiliated project,
[E-Halcyon](https://github.com/MercuryWorkshop/RecoMod) (UNMAINTAINED) to boot into an unenrolled environment temporarily.
This will bypass both issues of The Fog and The Tsunami, however further caveats are listed on the website.

[Shimboot](https://github.com/ading2210/shimboot) is a modern alternative to E-Halcyon. It additionally supports booting a desktop linux environment.

</details>

### R114 patch ("The Tsunami")
The patch at [crrev/c/4367525](https://crrev.com/c/4367525) forces write protect to be enabled when FWMP blocks developer mode.
On Ti50, it was released in r120.

<details>
<summary>"The Tsunami" Bypass Details</summary>

> [!WARNING]
> It is **_STRONGLY_** recommended to use a different exploit if possible.
> The instructions to bypass "_The Tsunami_" are potentially dangerous, even with a chip flasher. **Proceed with caution.**

If your Chromebook is on version 114 or newer,
unenrollment is still possible by [bridging two pins on the firmware chip](https://web.archive.org/web/20250424061912/https://blog.darkn.bio/blog/3-the-tsunami#bypassing-instructions) (internet archive is used because the domain was stolen and is now used for scams).
On most devices, this will require you to take off the back of the Chromebook and then use a piece of tinfoil, wire, or other conductive material to bridge the two pins.
This bypass is **not recommended** as you risk permanently bricking the Chromebook, so other methods should be used if available.

</details>

### Enrollment flow changes

The patch at [crrev/c/5454834](https://crrev.com/c/5454834) (r125) enabled unified state determination for *some* devices.  
The patch at [crrev/c/6309012](https://crrev.com/c/6309012) (r136) enabled unified state determination for all remaining devices.

With unified state determination enabled, even removing FWMP won't prevent re-enrollment.
Instead, the serial number or device secret should be changed, or it can temporarily be disabled in developer mode:

<details>
<summary>Bypass Details</summary>

#### r125-r135:

Powerwash, go to developer mode, enter VT2, and run these commands (make sure to type the `>` and `>>` exactly as you see them):
```
echo --enterprise-enable-unified-state-determination=never >/tmp/chrome_dev.conf
echo --enterprise-enable-forced-re-enrollment=never >>/tmp/chrome_dev.conf
echo --enterprise-enable-initial-enrollment=never >>/tmp/chrome_dev.conf
mount --bind /tmp/chrome_dev.conf /etc/chrome_dev.conf
initctl restart ui
```
Then switch out of VT2 and set up the device (don't reboot until you've finished setting it up).

#### r136+

Powerwash, go to developer mode, enter VT2, and run these commands:
```
echo --enterprise-enable-state-determination=never >/tmp/chrome_dev.conf
mount --bind /tmp/chrome_dev.conf /etc/chrome_dev.conf
initctl restart ui
```
Then switch out of VT2 and set up the device (don't reboot until you've finished setting it up).

</details>

</details>

## Related projects
<details>

- [shimboot](https://github.com/ading2210/shimboot) - Boot a desktop Linux distribution from a Chrome OS RMA shim
- <span style="color:grey">[RecoMod](https://github.com/MercuryWorkshop/RecoMod) - a cros recovery image modification toolkit (currently unmaintained)</span>
- <span style="color:grey">[fakemurk](https://github.com/MercuryWorkshop/fakemurk) - a set of scripts for spoofing verified mode on an enrolled chromebook (unmaintained)</span>
- <span style="color:grey">[terraOS](https://github.com/r58playz/terraos) - Boot Linux-based operating systems from a RMA shim (abandoned, use shimboot instead)</span>

### CryptoSmite
[GitHub](https://github.com/FWNavy/CryptoSmite)

Patched by [crrev/c/5010266](https://crrev.com/c/5010266) (r120, r114 LTS).  
Works on r119 (kernver 2) and lower.

This is bundled inside payloads in all SH1MMER shims; and all you need to do is boot SH1MMER, go to the payloads menu, and run the "Cryptosmite" payload.

### BadRecovery
[GitHub](https://github.com/BinBashBanana/badrecovery)

Patched by [crrev/c/5447828](https://crrev.com/c/5447828) (r125).  
Works on kernver 3 and lower (device version independent).

### Br1ck
[GitHub](https://github.com/veebyte/br1ck)

Patched by [crrev/c/6035435](https://crrev.com/c/6035435) (r132).  
Works on r131 (kernver 4) and lower.

### Icarus
[GitHub](https://github.com/cosmicdevv/Icarus-Lite)

Patched by [crrev/c/5805540](https://crrev.com/c/5805540) (r130).  
Works on r129 (kernver 4) and lower.

This is bundled inside payloads in all SH1MMER shims; and all you need to do is boot SH1MMER, go to the payloads menu, and run the "Icarus" payload.  
> [!NOTE]
> You will need to setup a server using the [Icarus repo](https://github.com/cosmicdevv/Icarus-Lite), and follow the steps to connect to the proxy after running the payload.
> The original repo by Writable can be found [here](https://github.com/MunyDev/icarus), however it is no longer working due to expired certificates.

### Br0ker
No GitHub

Patched by [crrev/c/6040974](https://crrev.com/c/6040974) (r133).  
Works on r132 (kernver 5) and lower.

This is bundled inside payloads in all SH1MMER shims; and all you need to do is boot SH1MMER, go to the payloads menu, and run the "Br0ker" payload.
You can also bundle the update file with the shim to automatically downgrade the device to a vulnerable version, assuming it has a low enough kernel version.
Instructions can be found at [wax/readme.br0ker.md](./wax/readme.br0ker.md)

</details>

## Credits

- [CoolElectronics](https://discord.com/users/696392247205298207) - Pioneering this wild exploit
- [ULTRA BLUE](https://discord.com/users/904487572301021265) - Testing & discovering how to disable RootFS verification
- [Unciaur](https://discord.com/users/465682780320301077) - Found the inital RMA shim
- [TheMemeSniper](https://discord.com/users/391271835901362198) - Testing
- [Rafflesia](https://discord.com/users/247349845298249728) - Hosting files
- [generic](https://discord.com/users/1052016750486638613) - Hosting alternative file mirror & crypto miner (troll emoji)
- [Bypassi](https://discord.com/users/904829646145720340) - Helped with the website
- [r58Playz](https://discord.com/users/803355425835188224) - Helped us set parts of the shim & made the initial GUI script
- [OlyB](https://discord.com/users/476169716998733834) - Scraped additional shims & last remaining sh1mmer maintainer
- [Sharp_Jack](https://discord.com/users/1006048734708240434) - Created wax & compiled the first shims
- [ember](https://discord.com/users/1052344689178722375) - Helped with the website
- [Mark](mailto:mark@mercurywork.shop) - Technical Understanding and Advisory into the ChromeOS ecosystem
