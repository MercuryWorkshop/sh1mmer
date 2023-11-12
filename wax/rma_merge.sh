#!/usr/bin/env bash

# use merge_nano.sh --help
# todo: make this script standalone

chmod +x lib/image_tool.py
lib/image_tool.py rma merge "$@"
