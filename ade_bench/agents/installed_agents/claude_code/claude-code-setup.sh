#!/bin/bash
echo "Setup Claude Code"

# Node.js should already be pre-installed in the Docker image
node --version
npm --version

echo "installing Claude Code"

# Pinned so benchmark runs on different days compare the same harness binary.
# Bump deliberately (and note it in run records), not implicitly.
npm install -g @anthropic-ai/claude-code@2.1.207

claude --version

echo "Installed Claude Code"
