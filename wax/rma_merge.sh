#!/usr/bin/env bash

# use merge_nano.sh --help
# todo: make this script standalone

chmod +x lib/py/image_tool.py
lib/py/image_tool.py rma merge "$@"
