#!/bin/bash
# Hex Agent Script: Claude Code
# 
# This script sends your transcription to Claude Code (claude CLI) for processing.
# If text was selected before recording, it's included as context.
#
# Requirements:
# - Claude Code CLI installed: https://docs.anthropic.com/en/docs/claude-code
# - Run: npm install -g @anthropic-ai/claude-code
#
# Input (JSON via stdin):
#   {"transcript": "your voice transcription", "selectedText": "optional selected text"}
#
# Output (stdout):
#   The response from Claude Code

set -e

# NSUserUnixTask runs with a minimal PATH, so we need to find claude ourselves
# Check common installation locations
CLAUDE_CMD=""
for path in \
    "/usr/local/bin/claude" \
    "/opt/homebrew/bin/claude" \
    "$HOME/.local/bin/claude" \
    "$HOME/.npm-global/bin/claude" \
    "$HOME/.nvm/versions/node/*/bin/claude" \
    "/usr/bin/claude"; do
    # Handle glob patterns
    for expanded in $path; do
        if [ -x "$expanded" ]; then
            CLAUDE_CMD="$expanded"
            break 2
        fi
    done
done

if [ -z "$CLAUDE_CMD" ]; then
    echo "Error: claude command not found. Please install Claude Code CLI:" >&2
    echo "  npm install -g @anthropic-ai/claude-code" >&2
    echo "" >&2
    echo "Or create a symlink in /usr/local/bin:" >&2
    echo "  sudo ln -s \$(which claude) /usr/local/bin/claude" >&2
    exit 1
fi

# Read JSON input from stdin
INPUT=$(cat)

# Parse JSON using built-in tools
TRANSCRIPT=$(echo "$INPUT" | python3 -c "import sys, json; print(json.load(sys.stdin).get('transcript', ''))")
SELECTED_TEXT=$(echo "$INPUT" | python3 -c "import sys, json; print(json.load(sys.stdin).get('selectedText') or '')")

# Build the prompt
if [ -n "$SELECTED_TEXT" ]; then
    PROMPT="Context (selected text):
$SELECTED_TEXT

Request:
$TRANSCRIPT"
else
    PROMPT="$TRANSCRIPT"
fi

# Run Claude Code with the prompt piped via stdin
# -p (--print): Output response directly without interactive mode
# --tools "": Disable all tools for pure text completion (no file access, no bash, etc.)
echo "$PROMPT" | "$CLAUDE_CMD" -p --tools ""
