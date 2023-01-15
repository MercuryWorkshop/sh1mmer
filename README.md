<div align="center">
    <h1>SH1MMER</h1>
</div>

Shady Hacking 1nstrument Makes Machine Enrollment Retreat

Website, source tree, and write-up for a ChromeOS enrollment jailbreak

## What is Shimmer?

Shimmer is an exploit found in the ChromeOS shim kernel that utilitzes modified RMA factory shims to gain code execution at recovery.<br>

## How does it work?

RMA shims are a factory tool allowing certain authorization functions to be is signed, but only
the KERNEL partitions are checked for signatures by the firmware. We can edit the other partitions to our will, as long as the characters contained
in those edits are equal to the amount of characters in the original.

## Credits

- CoolElectronics#4683 - Pioneering this wild exploit
- Bideos#1850 - Testing & discovering how to disable root-fs verification
- Unciaur#1408 - Found the inital RMA shim
- TheMemeSniper#6065 - Testing
- Rafflesia#8396 - Hosting files
- Bypassi#7037 - Helped with the website
- r58Playz#3467 - Helped us set parts of the shim & made the initial GUI script
- OlyB#9420 - Scraped additional shims
- Sharp_Jack#4374 - Created wax & compiled the first shims
