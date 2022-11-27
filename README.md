# sh1mmer.me
Seriously Harming IT's Moment of Magnificently Exclusive Rest

Website, name and write-up for a ChromeOS firmware boot exploit
# What is Shimmer?
Shimmer is an exploit found in the ChromeOS firmware that utilitzes the RMA factory shims to gain code execution at firmware recovery.
# How does it work?
This is achieved by putting the device into Developer Mode, and then booting a modified RMA shim from recovery mode. The shim is signed, but only 
the ROOT-A partition is checked for signatures by the firmware. We can edit the other partitions to our will, as long as the characters contained
in those edits are equal to the amount of characters in the original.
# Credits
* CoolElectronics#4683 - Pioneering this wild exploit
* Bideos#1850 - Testing & discovering how to disable root-fs verification
* Unciuar#1408 - Finding the SHIM files
* TheMemeSniper#6065 - Testing
* Rafflesia#8396 - Hosting files
* u/ijosephwalsh - Accidentally pushing us in the right direction by making a post on r/k12sysadmin about the Shimless RMA screen
