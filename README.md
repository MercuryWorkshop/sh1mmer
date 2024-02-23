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
If `chrome://version` is blocked, you can search up your Chromebook's model name on [chrome100](https://chrome100.dev)
and see what board it corresponds to. **DO NOT DOWNLOAD A RECOVERY IMAGE FROM [chrome100](https://chrome100.dev), IT WILL NOT WORK.**

If your board name is in the list below, great! Find the RAW RMA shim corresponding to your board online.
We can no longer provide raw RMA shims due to legal reasons. [**More information here**](https://discord.gg/egWXwEDWKP).

- (**A-B**) ambassador, brask, brya
- (**C-D**) clapper, coral, corsola, dedede
- (**D-G**) enguarde, glimmer, grunt
- (**H-N**) hana, hatch, jacuzzi, kukui
- (**L-P**) lulu, nami, octopus, orco, pyro
- (**R-S**) reks, sentry, stout, strongbad
- (**T-Z**) tidus, ultima, volteer, zork

If it's not, good luck. You'll have to try and call up your OEM and demand the files from them, which they are most unlikely to give to you.

***

### Building A Beautiful World Shim

> [!IMPORTANT]
> If you're using `coral`, `hana`, or some other older (pre-frecon) boards: <br />
> **DO NOT FOLLOW THESE INSTRUCTIONS!** Instead, skip to the "[Building A Legacy Shim](#building-a-legacy-shim)" section.

Now we can start building. Type out all of these commands in the terminal. You need to be on Linux or WSL2 and have the following packages installed: `git`, `wget`.

```
git clone https://github.com/MercuryWorkshop/sh1mmer
cd sh1mmer/wax
wget https://dl.osu.bio/api/raw/?path=/SH1mmer/Chromebrew/chromebrew.tar.gz
sudo bash wax.sh path/to/the/shim/you/downloaded.bin
```

> [!NOTE]
> If you want to build a devshim, replace `chromebrew.tar.gz` with `chromebrew-dev.tar.gz` and add `--dev` to the end of `sudo sh wax.sh /path/to/the/shim/you/downloaded.bin`.
> Devshim builds will mount a much larger Chromebrew partition over `/usr/local`,
> allowing you to access a desktop environment and even Firefox from within SH1MMER.
> It's what allowed us to [run DOOM on a shim](https://github.com/CoolElectronics/blog/blob/master/src/content/blog/breaking/doom.jpg?raw=true).

When this finishes, the bin file in the path you provided will have been converted into a **SH1MMER** image.
*Note that this is a destructive operation, you will need to redownload a fresh shim to try again if it fails.*

After injecting, you may continue to the "[Booting Into A Shim](#booting-into-a-shim)" section.

***

### Building A Legacy Shim

The raw shim files for boards such as `hana` or `coral` were built before graphics support was added into the tty.
This makes it impossible for the Beautiful World GUI to work and thus a legacy CLI-only shim must be built.

Type out all of these commands in the terminal. You need to be on Linux and have the following packages installed: `gdisk`, `e2fsprogs`.

```
git clone https://github.com/MercuryWorkshop/sh1mmer
cd sh1mmer/wax
sudo bash wax_legacy.sh -i path/to/the/shim/you/downloaded.bin
```

> [!NOTE]
> Building a legacy shim will work on **ALL BOARDS.** The legacy version of wax now also supports nano (shrunken) shims!
> After the file has been converted into a legacy shim the size can be up to 90% smaller than the original shim.

When this finishes, the bin file in the path you provided will have been converted into a **SH1MMER** image.
*Note that this is a destructive operation, you will need to redownload a fresh shim to try again if it fails.*

After injecting, you may continue to the "[Booting Into A Shim](#booting-into-a-shim)" section.

#### Preseeding

Once you've built a legacy shim, you can also 'preseed' it to run a shell script on boot rather than opening the menu:
```shell
sudo ./wax/inject_preseed.sh -s <path/to/legacy_shim.bin> -p <path/to/preseed/file.sh>
```
Preseed files can call any function defined in [factory_install.sh](https://github.com/MercuryWorkshop/sh1mmer/blob/beautifulworld/wax/sh1mmer_legacy/root/noarch/usr/sbin/factory_install.sh). See [here](https://github.com/MercuryWorkshop/sh1mmer/tree/beautifulworld/wax/preseed/examples) for examples.


***

### Booting Into A Shim

Once you have injected your raw shim with SH1MMER, go into the Chromebook Recovery Utility, select the settings icon (⚙️), select `Use local image`, and then select your injected shim.
Alternatively, you can also use other flashers such as [BalenaEtcher](https://etcher.balena.io/), [Rufus](https://rufis.ie), [UNetbootin](https://unetbootin.github.io/), and etc.
*This may take up to 10 minutes, depending on the size of your shim and speed of your USB drive.*

On the Chromebook, press `ESC + Refresh (↻) + Power (⏻)` at the same time to enter the recovery screen, then press `CTRL + D` at the same time and press Enter.
This should enable Developer Mode or turn off OS Verification.
*This may be blocked by system policy, but that doesn't matter.*

Press `ESC + Refresh (↻) + Power (⏻)` at the same time again, then plug in your USB with SH1MMER and you should be booting into the Beautiful World GUI or a CLI screen.
From here, you can play around with the options and do what you want.

***


### The Fog....

Downgrading and unenrollment has been patched by Google™️.
If your Chromebook has never updated to version 112 (or newer) before (check in `chrome://version`),
then you can ignore this and follow the normal instructions. If not, unenrollment will not work as normal.

<details>
    <summary>Fog Bypass Details</b></summary>

If your Chromebook is on version 112 or 113, unenrollment is still possible if you're willing to [disable hardware write protection]("https://mrchromebox.tech/#devices).
On most devices, this will require you to take off the back of the Chromebook and unplug the battery, or jump two pins.
Further instructions are on [the website](https://sh1mmer.me/#fog).

#### "Unenrolling" with Write Protection

If you aren't willing to take apart your Chromebook to unenroll, you can use an affiliated project,
[E-Halcyon](https://fog.gay) to boot into an unenrolled environment temporarily.
This will bypass both issues of The Fog and The Tsunami, however further caveats are listed on the website.

</details>

### The Tsunami

Disabling write protection has also been patched by Google™️.
If your Chromebook has never updated to version 114 (or newer) before (check in `chrome://version`),
then you can ignore this and follow the [Unpatch](https://sh1mmer.me/#fog:~:text=v111) instructions. If not, disabling 
write protection will not work as normal.

<details>
    <summary>Tsunami Bypass Details</b></summary>

If your Chromebook is on version 114 or newer,
unenrollment is still possible by [bridging two pins on the firmware chip](https://blog.osu.bio/blog/the-tsunami#bypassing-instructions).
On most devices, this will require you to take off the back of the Chromebook and then use a piece of tinfoil, wire, or other conductive material to bridge the two pins.
This bypass is **not recommended** as you risk permanently bricking the Chromebook, please use [E-Halcyon](https://fog.gay) instead.

</details>

## Credits

- [CoolElectronics](https://discord.com/users/696392247205298207) - Pioneering this wild exploit
- [ULTRA BLUE#1850](https://discord.com/users/904487572301021265) - Testing & discovering how to disable RootFS verification
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
