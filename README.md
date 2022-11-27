# sh1mmer.me
Seriously Harming One's Moment of Magnificently Exclusive Rest
Website, name and write-up for a ChromeOS firmware boot exploit
# What is SH1MMER?
SH1MMER is an exploit found in the ChromeOS firmware that utilitzes the RMA factory shims to gain code execution at firmware recovery.
# How does it work?
This is achieved by putting the device into Developer Mode, and then booting a modified RMA shim from recovery mode. The shim is signed, but only 
the ROOT-A partition is checked for signatures by the firmware. We can edit the other partitions to our will, as long as the characters contained
in those edits are equal to the amount of characters in the original.
# Credits
* CoolElectronics - Pioneering this wild exploit
* Bideos - Testing & discovering ROOT-A editing
* Unicar - Testing
* TheMemeSniper/Kaitlin - Testing
* Rafflesia - Testing
