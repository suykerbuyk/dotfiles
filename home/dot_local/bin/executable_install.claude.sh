#!/bin/bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

set -e
# https://claudecode.io/install
~/.nvm/nvm.sh install node --lts
npm install -g @anthropic-ai/claude-code
