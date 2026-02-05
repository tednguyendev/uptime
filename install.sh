#!/bin/bash
set -e

INSTALL_DIR="$HOME/.uptime"
PLUGIN_DIR="$HOME/Library/Application Support/SwiftBar/Plugins"

# Clone or update
if [ -d "$INSTALL_DIR" ]; then
  echo "Updating Uptime..."
  cd "$INSTALL_DIR" && git pull
else
  echo "Installing Uptime..."
  git clone https://github.com/tednguyendev/uptime.git "$INSTALL_DIR"
fi

# Symlink plugin
mkdir -p "$PLUGIN_DIR"
ln -sf "$INSTALL_DIR/plugin/uptime.1m.sh" "$PLUGIN_DIR/uptime.1m.sh"

echo "Done! Start SwiftBar if it's not running: open -a SwiftBar"
