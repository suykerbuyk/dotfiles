#!/bin/bash

set -e
# https://claudecode.io/install
~/.nvm/nvm.sh install node --lts
npm install -g @anthropic-ai/claude-code
