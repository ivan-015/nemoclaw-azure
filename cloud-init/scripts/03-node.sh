#!/usr/bin/env bash
# 03-node.sh — install Node.js 22 LTS via NodeSource on Ubuntu 24.04.
# NemoClaw upstream documents Node 22.16+ as the supported runtime.
#
# Inputs:
#   NODE_MAJOR       Major version (default 22; passed by template)

set -euo pipefail

NODE_MAJOR="${NODE_MAJOR:-22}"

echo "[03-node] installing Node.js ${NODE_MAJOR}.x via NodeSource"

apt-get install -y ca-certificates curl gnupg

mkdir -p /etc/apt/keyrings
curl -fsSL "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key" \
  | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
chmod a+r /etc/apt/keyrings/nodesource.gpg

echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
  > /etc/apt/sources.list.d/nodesource.list

apt-get update
apt-get install -y nodejs

echo "[03-node] node + npm versions:"
node --version
npm --version
