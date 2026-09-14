#!/usr/bin/env bash
# Installs the pinned Solidity dependencies into lib/ so `forge build` is reproducible.
#
# Pinned commits (see docs/DEPENDENCIES.md / contracts/DEPENDENCIES.md in the source repo):
#   forge-std               7fdf81f9ceb2f6ebbb8f9f1c6c5274d5bcc9a1f5  (v1.16.2)
#   v4-core                 46c6834698c48bc4a463a86d8420f4eb1d7f3b75  (v1.0.2, main)
#   v4-periphery            dce236d4e2057422d0791d9a973a58765eb46f65  (main)
#   openzeppelin-contracts  c547cd4d007bd7d887ea56e9086611a79844727d  (v5.7.0)
#
# v4-core and v4-periphery each pull nested libraries via git submodules
# (lib/v4-core/lib/solmate, lib/v4-core/lib/openzeppelin-contracts,
#  lib/v4-periphery/lib/v4-core, lib/v4-periphery/lib/permit2), so this script
# runs `git submodule update --init --recursive` inside each after checkout.
#
# Usage: ./scripts/install-deps.sh [lib-dir]   (default: lib)
set -euo pipefail

LIB_DIR="${1:-lib}"
mkdir -p "$LIB_DIR"

clone_pinned() {
  local url="$1" dest="$2" sha="$3"
  if [ -d "$dest" ]; then
    echo "skip (already exists): $dest"
    return
  fi
  echo "cloning $url @ $sha -> $dest"
  # -c core.longpaths=true works around Windows MAX_PATH failures on the
  # deeply nested submodule paths some of these repos pull in.
  git -c core.longpaths=true clone --quiet "$url" "$dest"
  (
    cd "$dest"
    git config core.longpaths true
    git checkout --quiet "$sha"
    git -c core.longpaths=true submodule update --init --recursive --quiet
  )
}

clone_pinned https://github.com/foundry-rs/forge-std.git               "$LIB_DIR/forge-std"              7fdf81f9ceb2f6ebbb8f9f1c6c5274d5bcc9a1f5
clone_pinned https://github.com/Uniswap/v4-core.git                    "$LIB_DIR/v4-core"                46c6834698c48bc4a463a86d8420f4eb1d7f3b75
clone_pinned https://github.com/Uniswap/v4-periphery.git               "$LIB_DIR/v4-periphery"           dce236d4e2057422d0791d9a973a58765eb46f65
clone_pinned https://github.com/OpenZeppelin/openzeppelin-contracts.git "$LIB_DIR/openzeppelin-contracts" c547cd4d007bd7d887ea56e9086611a79844727d

echo "Done. $LIB_DIR/ now has forge-std, v4-core, v4-periphery, and openzeppelin-contracts pinned to the exact commits above."
echo "Next: forge build"
