#!/usr/bin/env bash
#
# mayhem/build.sh — build libosrm's fuzz harnesses (sanitized, libFuzzer + standalone) and the unit
# tests (normal flags). Runs in the commit image as `mayhem` in /mayhem, offline: every dependency is
# resolved from apt packages or /opt/deps (see mayhem/Dockerfile and mayhem/install-deps.sh).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
export CMAKE_PREFIX_PATH=/opt/deps/prefix
COMMON_CMAKE=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DENABLE_LTO=OFF -DENABLE_CCACHE=OFF
              -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX")

# 1) Unit tests, project's NORMAL flags (separate tree; test.sh only runs them).
TESTS=(util-tests server-tests engine-tests extractor-tests partitioner-tests)
cmake -S . -B _build-tests "${COMMON_CMAKE[@]}" \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="-DBOOST_TEST_DYN_LINK $COVERAGE_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$COVERAGE_FLAGS"
cmake --build _build-tests --target "${TESTS[@]}" -j"$MAYHEM_JOBS"

# 2) The project itself, sanitized, with coverage instrumentation for libFuzzer (-no-link keeps the
#    fuzzer runtime out of the libraries; it is linked into each harness below).
FUZZ_COV=-fsanitize=fuzzer-no-link
FUZZ_FLAGS="$SANITIZER_FLAGS $FUZZ_COV $DEBUG_FLAGS"
B="$SRC/_build-fuzz"
cmake -S . -B "$B" "${COMMON_CMAKE[@]}" \
  -DCMAKE_C_FLAGS="$FUZZ_FLAGS" -DCMAKE_CXX_FLAGS="$FUZZ_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS"
cmake --build "$B" --target SERVER UTIL osrm -j"$MAYHEM_JOBS"

# 3) Harnesses (fuzz/*.cc, upstream's own), each linked twice: libFuzzer and standalone reproducer.
OUT="$B/harness"
mkdir -p "$OUT"
HARNESSES=(escape_json match_parameters nearest_parameters request_parser route_parameters
           table_parameters tile_parameters trip_parameters uri_decode url_parser)
CXXFLAGS_H=(-std=c++20 -O2 -ftemplate-depth=1024 -DOSRM_PROJECT_DIR=\""$SRC"\"
            -I"$SRC/include" -I"$B/include" -I"$SRC/fuzz"
            -isystem "$B/osrm_fbs" -isystem /opt/deps/prefix/include -isystem /usr/include/lua5.4)
mapfile -t OBJS < <(find "$B/CMakeFiles/SERVER.dir" "$B/CMakeFiles/UTIL.dir" -name '*.o' | sort)
LIBS=("$B/libosrm.a" -lboost_program_options -lboost_date_time -lboost_iostreams -lboost_thread
      -lboost_atomic -ltbb -lz -larchive -lrt)

$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$OUT/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$OUT/standalone_main.o"

for h in "${HARNESSES[@]}"; do
  $CXX $FUZZ_FLAGS "${CXXFLAGS_H[@]}" -c "$SRC/fuzz/$h.cc" -o "$OUT/$h.o"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$OUT/$h.o" "$OUT/lsan_off.o" \
    "${OBJS[@]}" "${LIBS[@]}" -o "$OUT/$h"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "$OUT/$h.o" "$OUT/standalone_main.o" "$OUT/lsan_off.o" \
    "${OBJS[@]}" "${LIBS[@]}" -o "$OUT/$h-standalone"
done
