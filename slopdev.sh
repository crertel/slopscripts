#!/usr/bin/env bash
# slopdev - Generate devenv.nix configurations from natural language descriptions
# Uses devenv.new API to generate Nix development environment configurations

set -euo pipefail

PROMPT=""

if [[ $# -gt 0 ]]; then
    # Non-interactive mode: use argument as prompt
    PROMPT="$*"
else
    # Interactive mode: prompt user for description
    echo "Enter environment description (e.g., 'Elixir and Phoenix with Postgres'):" >&2
    read -r PROMPT
fi

if [[ -z "$PROMPT" ]]; then
    echo "Error: No environment description provided" >&2
    exit 1
fi

# URL encode the prompt
ENCODED_PROMPT=$(printf '%s' "$PROMPT" | jq -sRr @uri)

# Make the API request and extract devenv_nix content
RESPONSE=$(curl -s -X POST \
    "https://devenv.new/api/generate?q=${ENCODED_PROMPT}" \
    --compressed \
    -H 'Accept: */*' \
    -H 'Origin: https://devenv.new' \
    -H 'Content-Length: 0')

# Parse JSON and output the devenv.nix content
echo "$RESPONSE" | jq -r '.devenv_nix'
