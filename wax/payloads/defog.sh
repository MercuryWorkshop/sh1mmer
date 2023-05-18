 #!/bin/bash
if crossystem wp_sw?1; then
    echo "WRITE PROTECTION NOT DISABLED!!!! YOU MUST DISABLE WRITE PROTECTION"
    return
fi
futility gbb --flash -s --flags=0x8090
crossystem block_devmode=0
vpd -i RW_VPD block_devmode=0
echo "GBB flags set. Devmode should now be unblocked"
read -p "Press enter to continue" t