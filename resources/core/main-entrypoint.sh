#!/bin/bash
set -e

BAKED_PATH="/home/frappe/frappe-bench/assets"
SHARED_PATH="/home/frappe/frappe-bench/shared-assets"
ASSETS_PATH="/home/frappe/frappe-bench/sites/assets"

# Fail loudly rather than serving an empty asset tree: if the baked assets are
# missing, something has shadowed them (e.g. a volume mounted over this path)
# and merging nothing would 404 every stylesheet with no obvious cause.
if [ ! -f "$BAKED_PATH/assets.json" ]; then
  echo "No assets.json under $BAKED_PATH — baked assets are missing or shadowed." >&2
  exit 1
fi

# Merge this image's assets into the shared volume instead of replacing it, so
# the previous build's files stay available. Asset filenames carry a content
# hash, so builds never collide, and during a rolling update a container still
# rendering the old manifest keeps getting served — no 404s while the swap is
# half done.
#
# `-L` dereferences the per-app symlinks (assets/frappe -> apps/frappe/.../public)
# so the volume holds real files, readable by every container.
mkdir -p "$SHARED_PATH"
# Stamp the whole tree, not just assets.json: that file lists only the hashed
# bundles, so a build that changes an image, font or favicon would otherwise
# look identical and get skipped.
stamp=$(cd "$BAKED_PATH" && find . -follow -type f -printf '%P %s\n' | sort | md5sum | cut -d' ' -f1)
if [ ! -f "$SHARED_PATH/.build-$stamp" ]; then
  echo "Merging assets of build $stamp into volume..."
  cp -rL "$BAKED_PATH"/. "$SHARED_PATH"/
  touch "$SHARED_PATH/.build-$stamp"
else
  echo "Assets of build $stamp already in volume."
fi

# Point sites/assets at the shared volume. The volume is mounted on its own
# path and linked from here rather than mounted straight onto sites/assets:
# a mount target that is already a symlink gets resolved to the symlink's
# target, which would shadow the baked assets above with the empty volume.
rm -rf "$ASSETS_PATH"
ln -s "$SHARED_PATH" "$ASSETS_PATH"

# ponytail: no pruning. Growth is small — asset names are content hashes, so
# unchanged bundles keep their name and are just overwritten; only bundles that
# actually changed pile up. If it ever does grow too big, stop the stack and
# `docker volume rm <project>_assets`: the next start repopulates it.
# ponytail: no lock — two containers starting at the exact same second both
# copy; same bytes, so worst case is wasted IO.
# ponytail: the stamp compares names and sizes, not content — an edit that
# keeps a file byte-for-byte the same size is missed. Hashed bundles are
# unaffected (their name changes); checksum the tree if it ever bites.

exec "$@"
