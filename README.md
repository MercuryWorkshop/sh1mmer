<div align="center">
    <h1>SH1MMER</h1>
</div>

Shady Hacking 1nstrument Makes Machine Enrollment Retreat

Website, source tree, and write-up for a ChromeOS enrollment jailbreak

## What is Shimmer?

Shimmer is an exploit found in the ChromeOS shim kernel that utilitzes modified RMA factory shims to gain code execution at recovery.<br>

## How do I use it?

The prebuilt binaries have been taken off of the official mirror (dl.sh1mmer.me), so you'll have to build it from source

Here's how you do that.
First, you need to know your chromebook's board. Go to chrome://version on your chromebook and copy the word after "stable-chnanel". If chrome://version is blocked, you can search up your chromebook's model name on chrome100.dev and see what board it corresponds to. DO NOT DOWNLOAD ANYTHING FROM CHROME100.DEV AND USE IT WITH THE BUILDER, IT WILL NOT WORK.

If your board name is in the list below, great! Download the RAW shim corresponding to your board from [here](https://files.ultimatesrv.com).

- brask, brya, clapper, coral, dedede, enguarde, glimmer, grunt, hana, hatch, jacuzzi, kukui, nami, octopus, orco, pyro, reks, sentry, stout, strongbad, tidus, ultima, volteer, zork

If it's not, good luck. You'll have to try and call up your OEM and demand the files from them, which they are unlikely to give to you.

Now we can start building. Type out all of these commands in the terminal. You need to be on linux/wsl2 and have the following packages installed: cgpt, git, wget

### Building a Beautiful World shim

IMPORTANT!!!! IF YOU HAVE EITHER THE `coral` OR `hana` BOARDS, DO NOT FOLLOW THESE INSTRUCTIONS, INSTEAD SKIP TO THE "Building a legacy shim" SECTION

```
git clone https://github.com/CoolElectronics/sh1mmer
cd sh1mmer/wax
wget https://dl.sh1mmer.me/build-tools/chromebrew/chromebrew.tar.gz
sudo sh wax.sh /path/to/the/shim/you/downloaded.bin
```

When this finishes, the bin file in the path you provided will have been converted into a sh1mmer image. Note that this is a destructive operation, you will need to redownload a fresh shim to try again if it fails.

If you want to build a devshim (higher file size but more features, such as a desktop environment and a web browser included in the shim), replace `chromebrew.tar.gz` with `chromebrew-dev.tar.gz` and add `--dev` to the end of `sudo sh wax.sh /path/to/the/shim/you/downloaded.bin`
The chromebrew tarballs are NOT COPYRIGHTED MATERIAL and can be distributed freely.

### Building a legacy shim

To install the built .bin file onto a usb, use the chrome recovery tool, rufus, or any other flasher.

## How does it work?

RMA shims are a factory tool allowing certain authorization functions to be is signed, but only
the KERNEL partitions are checked for signatures by the firmware. We can edit the other partitions to our will as long as we remove the forced readonly bit on them.

## Credits

- CoolElectronics#4683 - Pioneering this wild exploit
- ULTRA BLUE#1850 - Testing & discovering how to disable root-fs verification
- Unciaur#1408 - Found the inital RMA shim
- generic#6410 - Hosting alternative file mirror & crypto miner (troll emoji)
- TheMemeSniper#6065 - Testing
- Rafflesia#8396 - Hosting files
- Bypassi#7037 - Helped with the website
- r58Playz#3467 - Helped us set parts of the shim & made the initial GUI script
- OlyB#9420 - Scraped additional shims
- Sharp_Jack#4374 - Created wax & compiled the first shims
- ember#0377 - Helped with the website
- Mark - Technical Understanding and Advisory into the ChromeOS ecosystem
