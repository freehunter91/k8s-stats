#!/bin/bash
# This script is the container's entrypoint.
# It allows choosing between running the web server or the CLI tool.
set -e

# Check the first argument passed to the container
MODE=$1

echo "--- Kubernetes Pod Monitor Container ---"
echo "Selected mode: ${MODE}"

if [ "${MODE}" = "web" ]; then
    echo "Starting web server..."
    exec python web_server.py
elif [ "${MODE}" = "cli" ]; then
    echo "Running in CLI mode..."
    exec python main.py
else
    echo "Error: Unknown mode '${MODE}'."
    echo "Please use 'web' or 'cli'."
    exit 1
fi
