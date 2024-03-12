#!/bin/bash

write_kernver(){
  local data=$*
  
  tpmc write 0x1008 $data
}


# gotta make this really complicated because TPMC doesn't like when I try to read the full index on GRUNT BARLA....
read_kernver(){
  case $kernver in
    "0")
      cat /mnt/state/kvs/kernver0
      ;;
    "1")
      cat /mnt/state/kvs/kernver1
      ;;
    "2")
      cat /mnt/state/kvs/kernver2
      ;;
    "3")
      cat /mnt/state/kvs/kernver3
      ;;
    "*")
      panic "invalid-kernver"
      ;;
    esac
}
