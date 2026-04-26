#!/usr/bin/env bash
# 02-docker.sh — install Docker CE from the upstream Docker repo on
# Ubuntu 24.04 (noble). Pinning is via DOCKER_VERSION (Terraform-
# templated). Constitution Principle V: explicit version pin.
#
# Inputs:
#   DOCKER_VERSION   Pinned upstream version (e.g. 5:27.5.1-1~ubuntu.24.04~noble)
#                    Defaults to "" — falls through to the repo's
#                    current `latest`. The cloud-init template MUST
#                    pass an explicit version for reproducibility.

set -euo pipefail

DOCKER_VERSION="${DOCKER_VERSION:-}"

echo "[02-docker] installing prerequisites"
apt-get update
apt-get install -y ca-certificates curl gnupg

echo "[02-docker] adding Docker apt repository"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update

if [[ -n "$DOCKER_VERSION" ]]; then
  echo "[02-docker] installing pinned version: $DOCKER_VERSION"
  apt-get install -y \
    "docker-ce=$DOCKER_VERSION" \
    "docker-ce-cli=$DOCKER_VERSION" \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin
else
  echo "[02-docker] WARNING: no DOCKER_VERSION pin — using repo latest"
  apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin
fi

systemctl enable --now docker
echo "[02-docker] daemon up. version:"
docker --version
