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
wget https://dl.darkn.bio/api/raw/?path=/Chromebrew/chromebrew.tar.gz
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
> Building a legacy shim will work on **ALL BOARDS.** Legacy shims are easier to update and are
> recommended for advanced users and developers.

When this finishes, the bin file in the path you provided will have been converted into a **SH1MMER** image.
*Note that this is a destructive operation, you will need to redownload a fresh shim to try again if it fails.*

After injecting, you may continue to the "[Booting Into A Shim](#booting-into-a-shim)" section.

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

> [!NOTE]
> On `hana` and `elm` devices, you may need to re-enter recovery mode quickly after enabling developer mode
> (skipping the "OS verification is OFF" screen).

***
### Icarus
SH1MMER and CryptoSmite have been patched by Google since v120, but since then a new unenrollment exploit for v125-v127 has released!
By default, this is bundled inside payloads in all SH1MMER shims; and all you need to do is boot SH1MMER, go to the payloads menu, and run the "Icarus" payload.  
**NOTE:** YOU WILL NEED TO SETUP A SERVER USING THE [Icarus repo](https://github.com/cosmicdevv/Icarus-Lite), AND FOLLOW THE STEPS TO CONNECT TO THE PROXY AFTER RUNNING THE PAYLOAD.  Original repo by Writable can be found [here](https://github.com/MunyDev/icarus), however it is no longer working due to expired certificates.  
### CryptoSmite
SH1MMER has been patched by Google since v111, but since then a new unenrollment exploit for v119 and lower has released: [CryptoSmite](https://github.com/FWSmasher/CryptoSmite).
By default, this is bundled inside payloads in all SH1MMER shims; and all you need to do is boot SH1MMER, go to the payloads menu, and run the "Cryptosmite" payload.

### R111 patch ("The Fog")
> [!NOTE]
> It is recommended to use CryptoSmite instead if you're only affected by "_The Fog_" and nothing else.
> "_The Fog_" instructions are old, however that doesn't mean you can't try it _**if**_ you don't wish to use CryptoSmite.

Unenrollment via SH1MMER has been patched by Google on Cr50/Ti50 devices.
If your Chromebook has never updated to version 112 (or newer) before (check in `chrome://version`),
then you can ignore this and follow the normal instructions. If not, unenrollment will not work as normal.

<details>
<summary>Fog Bypass Details</summary>

If your Chromebook is on version 112 or 113, unenrollment is still possible if you're willing to [disable hardware write protection]("https://mrchromebox.tech/#devices).
On most devices, this will require you to take off the back of the Chromebook and unplug the battery, or jump two pins.
Further instructions are on [the website](https://sh1mmer.me/#fog).

#### "Unenrolling" with Write Protection

If you aren't willing to take apart your Chromebook to unenroll, you can use an affiliated project,
[E-Halcyon](https://github.com/MercuryWorkshop/RecoMod) to boot into an unenrolled environment temporarily.
This will bypass both issues of The Fog and The Tsunami, however further caveats are listed on the website.

</details>

### R114 patch ("The Tsunami")

> [!WARNING]
> It is **_STRONGLY_** recommended to use CryptoSmite instead if you're on v119 or lower.
> The instructions to bypass "_The Tsunami_" are potentially dangerous, even with a chip flasher. **Proceed with caution if you can't use CryptoSmite.**

Disabling write protection has also been patched by Google on Cr50/Ti50 devices.
If your Chromebook has never updated to version 114 (or newer) before (check in `chrome://version`),
then you can ignore this and follow the [Unpatch](https://sh1mmer.me/#fog:~:text=v111) instructions. If not, disabling 
write protection will not work as normal.

<details>
<summary>Tsunami Bypass Details</summary>

If your Chromebook is on version 114 or newer,
unenrollment is still possible by [bridging two pins on the firmware chip](https://blog.darkn.bio/blog/the-tsunami#bypassing-instructions).
On most devices, this will require you to take off the back of the Chromebook and then use a piece of tinfoil, wire, or other conductive material to bridge the two pins.
This bypass is **not recommended** as you risk permanently bricking the Chromebook, please use [E-Halcyon](https://github.com/MercuryWorkshop/RecoMod) instead.

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
