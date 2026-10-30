#!/usr/bin/env bash
# Run as root at image-build time (see mayhem/Dockerfile). Installs the dependencies that vcpkg
# provides upstream but Debian does not package (sol2, vtzero, gauche) from the exact releases the
# upstream vcpkg overlay ports pin, into /opt/deps. build.sh resolves them from there offline.
set -euo pipefail
SRC="${SRC:-/mayhem}"
DEPS=/opt/deps
mkdir -p "$DEPS/src" "$DEPS/prefix"
cd "$DEPS/src"

fetch() { # name url sha512
  curl -fsSL --retry 5 "$2" -o "$1.tgz"
  echo "$3  $1.tgz" | sha512sum -c -
  mkdir -p "$1" && tar xzf "$1.tgz" -C "$1" --strip-components=1 && rm "$1.tgz"
}

fetch sol2 https://github.com/ThePhD/sol2/archive/refs/tags/v3.3.1.tar.gz \
  4404b124a4f331d77459c01a92cd73895301e7d3ef829a0285980f0138b9cc66782de3713d54f017d5aad7d8a11d23eeffbc5f3b39ccb4d4306a955711d385dd
fetch vtzero https://github.com/mapbox/vtzero/archive/refs/tags/v1.2.0.tar.gz \
  ddf3b6e61ffe18d5fd8c7e9c4a3e84a0e70854d56fd1303838b763eb8cd10abdb74079bd5c676fa9eb55d990b030ce4da9d94363fb03ca503d14da8f9e97a3b7
fetch gauche https://github.com/Project-OSRM/gauche-rs/archive/b1c3af3029975ddbe573bad874c4520db77321d0.tar.gz \
  b1ad5bbb45ea714005ffe8c2f34bde694448e507d8307818113b31a7288e6958b747660d614337004ea793b82a5ba1fbe02449dee7d06e271a4527741d147840

OVERLAY="$SRC/vcpkg-overlay-ports"
for p in header-only fix-noexcept-lua-cfunction fix-optional-reference-emplace; do
  patch -d sol2 -p1 < "$OVERLAY/sol2/$p.patch"
done
sed -i 's/LUA_VERSION_NUM > 504/LUA_VERSION_NUM > 505/' sol2/include/sol/compatibility/compat-5.3.h
sed -i 's/LUA_VERSION_NUM == 504/LUA_VERSION_NUM >= 504/' sol2/include/sol/compatibility/compat-5.4.h
patch -d gauche -p1 < "$OVERLAY/gauche/fix-msvc-interlocked-casts.patch"

cmake -S sol2 -B sol2/_b -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$DEPS/prefix"
cmake --install sol2/_b
cmake -S vtzero -B vtzero/_b -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTS=OFF -DCMAKE_INSTALL_PREFIX="$DEPS/prefix"
cmake --install vtzero/_b
cmake -S gauche/cpp -B gauche/_b -G Ninja -DCMAKE_BUILD_TYPE=Release -DGAUCHE_BUILD_EXAMPLES=OFF \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_INSTALL_PREFIX="$DEPS/prefix"
cmake --build gauche/_b
cmake --install gauche/_b
rm -rf sol2/_b vtzero/_b gauche/_b
