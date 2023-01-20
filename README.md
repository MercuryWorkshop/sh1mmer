
<div align="center">
    <h1>SH1MMER</h1>
</div>

Shady Hacking 1nstrument Makes Machine Enrollment Retreat

Website, source tree, and write-up for a ChromeOS enrollment jailbreak

## What is Shimmer?

Shimmer is an exploit found in the ChromeOS shim kernel that utilitzes modified RMA factory shims to gain code execution at recovery.<br>

## How do I use it?
The prebuilt binaries have been taken off of the official mirror (dl.sh1mmer.me), partially due to copyright concerns but also we're honestly tired of all the harassment and toxicity from the community, and from now on you'll have to build it from source.

Here's how you do that.
First, get a raw shim. There are several ways you can do this, from "borrowing" them from repair centers, accquiring a certified repair account, or in our case, [finding them online](https://lenovo-driver-download.com/cat/LAPTOPS-AND-NETBOOKS/LENOVO-CHROMEBOOKS-SERIES). Go on chrome100.dev and search for your chromebook's model. It will be in a box with other chromebook models. If one of those models corresponds with one on the lenovo website, download it.

Now we can start building. Type out all of these commands in the terminal. You need to be on linux/wsl and have the following packages installed: cgpt, git, wget
```
git clone https://github.com/CoolElectronics/sh1mmer
cd sh1mmer/wax
wget https://dl.sh1mmer.me/build-tools/chromebrew/chromebrew.tar.gz
sudo sh wax.sh /path/to/the/shim/you/downloaded.bin
```
When this finishes, the bin file in the path you provided will have been converted into a sh1mmer image. Note that this is a destructive operation, you will need to redownload a fresh shim to try again if it fails.

If you want to build a devshim (higher file size but more features), replace `chromebrew.tar.gz` with `chromebrew-dev.tar.gz` and add `--dev` to the end of `sudo sh wax.sh /path/to/the/shim/you/downloaded.bin`
The chromebrew tarballs are NOT COPYRIGHTED MATERIAL and can be distributed freely.

To install the built .bin file onto a usb, use the chrome recovery tool, rufus, or any other flasher.
## How does it work?

RMA shims are a factory tool allowing certain authorization functions to be is signed, but only
the KERNEL partitions are checked for signatures by the firmware. We can edit the other partitions to our will as long as we remove the forced readonly bit on them.

## Credits

- CoolElectronics#4683 - Pioneering this wild exploit
- Bideos#1850 - Testing & discovering how to disable root-fs verification
- Unciaur#1408 - Found the inital RMA shim
- generic#6410 - Hosting alternative file mirror & crypto miner (troll emoji)
- TheMemeSniper#6065 - Testing
- Rafflesia#8396 - Hosting files
- Bypassi#7037 - Helped with the website
- r58Playz#3467 - Helped us set parts of the shim & made the initial GUI script
- OlyB#9420 - Scraped additional shims
- Sharp_Jack#4374 - Created wax & compiled the first shims
- ember#0377 - Helped with the website
