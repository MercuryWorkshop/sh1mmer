<div align="center">
<h1>
    SH1MMER
</h1>
    
<h3>
    Shady Hardware 1nstrument Makes Machine Enrollment Retreat
</h3>

<i>
    Website, source tree, and write-up for a ChromeOS:tm: enrollment jailbreak
</i>
</div>

## The Fog....

Downgrading and unenrollment has been patched by Google:tm:.
If your Chromebook has never updated to version 112 (or newer) before (check in `chrome://version`),
then you can ignore this and follow the normal instructions. If not, unenrollment will not work as normal.

If your Chromebook is on version 112 or 113, unenrollment is still possible if you're willing to
[disable hardware write protection](https://mrchromebox.tech/#devices).
On most devices, this will require you to take off the back of the Chromebook and unplug the battery, or jump two pins.
Further instructions are on [the website](https://sh1mmer.me/#fog).

### The Tsunami

Disabling write protection has also been patched by Google:tm:.
If your Chromebook has never updated to 114 (or newer) before (check in `chrome://version`),
then you can ignore this and proceed with disabling write protection to continue using SH1MMER.
If not, unenrolling through disabling write protection will not work as normal.

If your Chromebook is on version 114 or newer,
unenrollment is still possible by [bridging two pins on the firmware chip](https://blog.coolelectronics.me/breaking-cros-6/#:~:text=the%20pencil%20bypass).
On most devices, this will require you to take off the back of the Chromebook and then use a piece of tinfoil, wire, or other conductive material to bridge the two pins.
Instructions are not listed and this solution is **not recommended** as you risk damaging the Chromebook.  
If you are aware of the risk and are still willing to perform this, be aware that you must bridge the WP
and VCC pins, **NOT** WP and GND, despite what the blog post says. Look up the model of your chip online,
most will be 8/16/32 MB (64/128/256 Mb). Find the pinout for WP and VCC. Most will use pins 3 and 8 respectively.

#### "Unenrollment" Without Disabling Hardware Write Protection

If you aren't willing to take apart your Chromebook to unenroll, you can use an affiliated project,
[E-Halcyon](https://fog.gay) to boot into a deprovisioned environment temporarily.
This will bypass both issues of The Fog and The Tsunami, however further caveats are listed on the website.

## What is SH1MMER?

**SH1MMER** is an exploit found in the ChromeOS shim kernel that utilitzes modified RMA factory shims to gain code execution at recovery.  
For more info, check out the blog post/writeup [here](https://blog.coolelectronics.me/breaking-cros-2/)

#### How does it work?

RMA shims are a factory tool allowing certain authorization functions to be signed,
but only the KERNEL partitions are checked for signatures by the firmware.
We can edit the other partitions to our will as long as we remove the forced readonly bit on them.

## How do I use it?

The prebuilt binaries have been taken off of the official mirror ([dl.sh1mmer.me](https://dl.sh1mmer.me)), so you'll have to build it from source.

Here's how you do that.
First, you need to know your Chromebook's board. Go to `chrome://version` on your Chromebook and copy the word after `stable-channel`.
If `chrome://version` is blocked, you can search up your Chromebook's model name on [chrome100](https://chrome100.dev)
and see what board it corresponds to. **DO NOT DOWNLOAD A RECOVERY IMAGE FROM [chrome100](https://chrome100.dev), IT WILL NOT WORK.**

If your board name is in the list below, great! Find the RAW RMA shim corresponding to your board online.
We can no longer provide raw RMA shims due to legal reasons. **[More information](https://discord.gg/egWXwEDWKP)**

- (**B**) brask, brya
- (**C**) clapper, coral, corsola
- (**D-E**) dedede, enguarde
- (**G**) glimmer, grunt
- (**H**) hana, hatch
- (**J-N**) jacuzzi, kukui, nami
- (**O**) octopus, orco
- (**P-R**) pyro, reks
- (**S**) sentry, stout, strongbad
- (**T-Z**) tidus, ultima, volteer, zork

If it's not, good luck. You'll have to try and call up your OEM and demand the files from them, which they are most unlikely to give to you.

***

### Building A Beautiful World Shim

**IMPORTANT!!!!** IF YOU HAVE EITHER THE `coral` OR `hana` BOARDS, OR SOME OTHER OLDER BOARDS (which?),
DO NOT FOLLOW THESE INSTRUCTIONS, INSTEAD SKIP TO THE "[Building A Legacy Shim](#building-a-legacy-shim)" SECTION

Now we can start building. Type out all of these commands in the terminal. You need to be on Linux or WSL2 and have the following packages installed: `git`, `wget`.
Note that WSL doesn't work for some people, and if you have trouble building it it's recommended to just use a VM or the [web builder](https://sh1mmer.me/builder.html).
**THE WEB BUILDER DOES NOT INCLUDE PAYLOADS!! YOU MUST BUILD IT MANUALLY FROM SOURCE FOR PAYLOADS**

```
git clone https://github.com/MercuryWorkshop/sh1mmer
cd sh1mmer/wax
wget https://dl.sh1mmer.me/build-tools/chromebrew/chromebrew.tar.gz
sudo bash wax.sh path/to/the/shim/you/downloaded.bin
```

When this finishes, the bin file in the path you provided will have been converted into a **SH1MMER** image.
Note that this is a destructive operation, you will need to redownload a fresh shim to try again if it fails.

> *If you want to build a devshim, replace `chromebrew.tar.gz` with `chromebrew-dev.tar.gz` and add `--dev` to the end of `sudo sh wax.sh /path/to/the/shim/you/downloaded.bin`
Devshim builds will mount a much larger Chromebrew partition over `/usr/local`,
allowing you to access a desktop environment and even FireFox from within SH1MMER.
It's what allowed us to [run doom on a shim](https://blog.coolelectronics.me/_astro/doom.82b5613a_Z1LR94C.webp).*

After injecting, you may continue to the "[Booting Into A Shim](#booting-into-a-shim)" section.

***

### Building A Legacy Shim

The raw shim files for boards such as `HANA` or `CORAL` were built before graphics support was added into the tty.
This makes it impossible for the Beautiful World GUI to work and thus a legacy CLI-only shim must be built.

Type out all of these commands in the terminal. You need to be on linux and have the following packages installed: `git`, `wget`.

Note that the legacy shim **will work on all boards**. The legacy version of wax now supports nano (shrunken) shims!

```
git clone https://github.com/MercuryWorkshop/sh1mmer
cd sh1mmer/wax
sudo bash wax_legacy.sh path/to/the/shim/you/downloaded.bin
```

After injecting, you may continue to the "[Booting Into A Shim](#booting-into-a-shim)" section.

***

### Booting Into A Shim

Once you have injected your raw shim with SH1MMER, go into the Chromebook Recovery Utility, select the settings icon (⚙️), select `Use local image`, and then select your injected shim.
Alternatively, you can also use other flashers such as BalenaEtcher, Rufus, UNetbootin, and etc.
*This may take up to 10 minutes, depending on the size of your shim and speed of your USB drive.*

On the Chromebook, press `ESC + Refresh (↻) + Power (⏻)` at the same time to enter the recovery screen, then press `CTRL + D` at the same time and press Enter.
This should enable Developer Mode or turn off OS Verification.
*This may be blocked by system policy, but that doesn't matter.*

Press `ESC + Refresh (↻) + Power (⏻)` at the same time again, then plug in your USB with SH1MMER and you should be booting into the Beautiful World GUI or a CLI screen.
From here, you can play around with the options and do what you want.

## Credits

- [CoolElectronics](https://discord.com/users/696392247205298207) - Pioneering this wild exploit
- [ULTRA BLUE#1850](https://discord.com/users/904487572301021265) - Testing & discovering how to disable rootfs verification
- [Unciaur](https://discord.com/users/465682780320301077) - Found the inital RMA shim
- [TheMemeSniper](https://discord.com/users/391271835901362198) - Testing
- [Rafflesia](https://discord.com/users/247349845298249728) - Hosting files
- [generic](https://discord.com/users/1052016750486638613) - Hosting alternative file mirror & crypto miner (troll emoji)
- [Bypassi](https://discord.com/users/904829646145720340) - Helped with the website
- [r58Playz](https://discord.com/users/803355425835188224) - Helped us set parts of the shim & made the initial GUI script
- [OlyB](https://discord.com/users/476169716998733834) - Scraped additional shims
- [Sharp_Jack](https://discord.com/users/1006048734708240434) - Created wax & compiled the first shims
- [ember#0377](https://discord.com/users/858866662869958668) - Helped with the website
- [Mark](https://discord.com/users/661272282903347201) - Technical Understanding and Advisory into the ChromeOS ecosystem
