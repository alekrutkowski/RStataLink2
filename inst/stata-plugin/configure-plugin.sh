#!/bin/sh
set -e

if [ "${RSTATALINK2_SKIP_PLUGIN:-}" = "1" ]; then
  echo "RStataLink2: skipping Stata plugin build because RSTATALINK2_SKIP_PLUGIN=1"
  exit 0
fi

ROOT_DIR=`pwd`
PLUGIN_DIR="${ROOT_DIR}/inst/stata-plugin"
TARGET="rslng__plugin.plugin"
BUILD_DIR="${PLUGIN_DIR}/build"
WINDOWS="${RSL2_WINDOWS:-0}"

if [ ! -d "${PLUGIN_DIR}" ]; then
  echo "RStataLink2 configure error: cannot find ${PLUGIN_DIR}" >&2
  exit 1
fi

cd "${PLUGIN_DIR}"

echo "RStataLink2: preparing Stata plugin build"

# Locate Rscript and R itself. R sets R_HOME during package installation.
R_ARCH_BIN=${R_ARCH_BIN:-}
if [ -n "${R_HOME:-}" ] && [ -x "${R_HOME}/bin${R_ARCH_BIN}/Rscript" ]; then
  R_SCRIPT="${R_HOME}/bin${R_ARCH_BIN}/Rscript"
elif [ -n "${R_HOME:-}" ] && [ -x "${R_HOME}/bin/Rscript" ]; then
  R_SCRIPT="${R_HOME}/bin/Rscript"
else
  R_SCRIPT="Rscript"
fi

if [ -n "${R_HOME:-}" ] && [ -x "${R_HOME}/bin${R_ARCH_BIN}/R" ]; then
  R_CMD="${R_HOME}/bin${R_ARCH_BIN}/R"
elif [ -n "${R_HOME:-}" ] && [ -x "${R_HOME}/bin/R" ]; then
  R_CMD="${R_HOME}/bin/R"
else
  R_CMD="R"
fi

run_rscript() {
  "${R_SCRIPT}" --vanilla "$@"
}

# Use R's compiler where possible so the build follows the active Rtools/R
# toolchain rather than a random compiler earlier on PATH.
if [ -z "${CC:-}" ]; then
  CC=`"${R_CMD}" CMD config CC | tail -n 1`
fi
if [ -z "${CFLAGS:-}" ]; then
  CFLAGS=`"${R_CMD}" CMD config CFLAGS | tail -n 1`
fi
export CC CFLAGS

run_rscript fetch-stata-spi.R .

append_platform_libs() {
  if [ "${WINDOWS}" = "1" ]; then
    echo " -lws2_32 -lmswsock -liphlpapi -lbcrypt -ladvapi32"
  else
    case `uname -s 2>/dev/null || echo unknown` in
      Darwin) echo "" ;;
      *) echo " -pthread" ;;
    esac
  fi
}

static_archive_link() {
  archive="$1"
  case `uname -s 2>/dev/null || echo unknown` in
    Darwin) echo "-Wl,-force_load,${archive}" ;;
    *) echo "-Wl,--whole-archive ${archive} -Wl,--no-whole-archive" ;;
  esac
}

nng_warning_flags() {
  if [ -n "${RSTATALINK2_NNG_CFLAGS+x}" ]; then
    echo "${RSTATALINK2_NNG_CFLAGS}"
    return 0
  fi
  # Keep bundled third-party NNG build logs readable under GCC/Clang.
  # These flags are used only for the bundled NNG dependency, not for
  # rslng_plugin.c itself.
  if ${CC:-cc} --version 2>/dev/null | grep -Ei "gcc|clang" >/dev/null 2>&1; then
    echo "-Wno-unused-parameter -Wno-cast-function-type -Wno-missing-field-initializers"
  else
    echo ""
  fi
}

try_pkg_config() {
  if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists nng 2>/dev/null; then
    NNG_CFLAGS=`pkg-config --cflags nng`
    NNG_LIBS="`pkg-config --libs nng` `append_platform_libs`"
    NNG_PREFIX_USED=`pkg-config --variable=prefix nng 2>/dev/null || echo ""`
    NNG_STATIC=0
    echo "RStataLink2: found NNG via pkg-config"
    return 0
  fi
  return 1
}

try_prefix() {
  pfx="$1"
  [ -n "${pfx}" ] || return 1
  [ -f "${pfx}/include/nng/nng.h" ] || return 1

  NNG_CFLAGS="-I${pfx}/include"
  NNG_STATIC=0

  if [ -f "${pfx}/lib/libnng.a" ]; then
    NNG_CFLAGS="${NNG_CFLAGS} -DNNG_STATIC_LIB"
    NNG_LIBS="`static_archive_link "${pfx}/lib/libnng.a"``append_platform_libs`"
    NNG_STATIC=1
  elif [ -f "${pfx}/lib/libnng.dll.a" ]; then
    NNG_LIBS="-L${pfx}/lib -lnng`append_platform_libs`"
    NNG_STATIC=0
  elif [ -f "${pfx}/lib/libnng.so" ] || [ -f "${pfx}/lib/libnng.dylib" ]; then
    NNG_LIBS="-L${pfx}/lib -lnng`append_platform_libs`"
    NNG_STATIC=0
  else
    return 1
  fi

  NNG_PREFIX_USED="${pfx}"
  echo "RStataLink2: found NNG under ${pfx}"
  return 0
}

build_bundled_nng() {
  if [ "${RSTATALINK2_NO_BUNDLE_NNG:-}" = "1" ]; then
    return 1
  fi
  if ! command -v cmake >/dev/null 2>&1; then
    echo "RStataLink2: cmake not found; cannot build bundled NNG" >&2
    return 1
  fi

  NNG_VERSION="${RSTATALINK2_NNG_VERSION:-1.11}"
  mkdir -p "${BUILD_DIR}"
  NNG_PATH_FILE="${BUILD_DIR}/nng-source-path.txt"
  rm -f "${NNG_PATH_FILE}"
  run_rscript fetch-nng.R "${BUILD_DIR}" "${NNG_VERSION}" "${NNG_PATH_FILE}"
  if [ ! -s "${NNG_PATH_FILE}" ]; then
    echo "RStataLink2 configure error: fetch-nng.R did not write ${NNG_PATH_FILE}" >&2
    return 1
  fi
  NNG_SRC=`sed -n '1p' "${NNG_PATH_FILE}" | tr -d '\r'`
  if [ ! -f "${NNG_SRC}/CMakeLists.txt" ]; then
    echo "RStataLink2 configure error: invalid NNG source directory: ${NNG_SRC}" >&2
    return 1
  fi

  NNG_PREFIX_USED="${BUILD_DIR}/nng-install"
  CMAKE_BUILD="${BUILD_DIR}/nng-cmake"

  echo "RStataLink2: compiling bundled NNG ${NNG_VERSION}"
  rm -rf "${CMAKE_BUILD}" "${NNG_PREFIX_USED}"
  NNG_CMAKE_CFLAGS="${CFLAGS} `nng_warning_flags`"

  if [ "${WINDOWS}" = "1" ]; then
    cmake -G "Unix Makefiles" \
      -S "${NNG_SRC}" \
      -B "${CMAKE_BUILD}" \
      -DCMAKE_INSTALL_PREFIX="${NNG_PREFIX_USED}" \
      -DCMAKE_INSTALL_LIBDIR=lib \
      -DCMAKE_C_FLAGS="${NNG_CMAKE_CFLAGS}" \
      -DBUILD_SHARED_LIBS=OFF \
      -DNNG_TESTS=OFF \
      -DNNG_TOOLS=OFF \
      -DNNG_ENABLE_NNGCAT=OFF \
      -DNNG_ENABLE_TLS=OFF \
      -DNNG_ENABLE_STATS=OFF \
      -DNNG_ENABLE_DOC=OFF \
      -DNNG_TRANSPORT_TCP=ON \
      -DNNG_TRANSPORT_IPC=ON \
      -DNNG_TRANSPORT_INPROC=ON \
      -DNNG_PROTO_PAIR0=ON \
      -DNNG_PROTO_REQ0=ON \
      -DNNG_PROTO_REP0=ON
  else
    cmake \
      -S "${NNG_SRC}" \
      -B "${CMAKE_BUILD}" \
      -DCMAKE_INSTALL_PREFIX="${NNG_PREFIX_USED}" \
      -DCMAKE_INSTALL_LIBDIR=lib \
      -DCMAKE_C_FLAGS="${NNG_CMAKE_CFLAGS}" \
      -DBUILD_SHARED_LIBS=OFF \
      -DNNG_TESTS=OFF \
      -DNNG_TOOLS=OFF \
      -DNNG_ENABLE_NNGCAT=OFF \
      -DNNG_ENABLE_TLS=OFF \
      -DNNG_ENABLE_STATS=OFF \
      -DNNG_ENABLE_DOC=OFF \
      -DNNG_TRANSPORT_TCP=ON \
      -DNNG_TRANSPORT_IPC=ON \
      -DNNG_TRANSPORT_INPROC=ON \
      -DNNG_PROTO_PAIR0=ON \
      -DNNG_PROTO_REQ0=ON \
      -DNNG_PROTO_REP0=ON
  fi

  cmake --build "${CMAKE_BUILD}" --target install --config Release

  # Bundled NNG is built as a static archive.  Prefer the explicit archive
  # path so we can link with whole-archive flags and retain all transport code.
  try_prefix "${NNG_PREFIX_USED}"
}

copy_runtime_dlls() {
  pfx="$1"
  [ "${WINDOWS}" = "1" ] || return 0
  [ "${NNG_STATIC:-0}" = "0" ] || return 0
  [ -n "${pfx}" ] || return 0
  for pat in "${pfx}"/bin/libnng*.dll "${pfx}"/bin/nng*.dll "${pfx}"/bin/libmbed*.dll "${pfx}"/bin/mbed*.dll; do
    for f in $pat; do
      if [ -f "$f" ]; then
        echo "RStataLink2: copying runtime DLL `basename "$f"`"
        cp "$f" .
      fi
    done
  done
}

NNG_CFLAGS=""
NNG_LIBS=""
NNG_PREFIX_USED=""
NNG_STATIC=0

if [ -n "${NNG_PREFIX:-}" ]; then
  try_prefix "${NNG_PREFIX}" || {
    echo "RStataLink2 configure error: NNG_PREFIX is set but NNG headers/library were not found under ${NNG_PREFIX}" >&2
    exit 1
  }
elif try_pkg_config; then
  :
else
  for p in /ucrt64 /mingw64 /clang64 /usr/local /usr /opt/homebrew /opt/local; do
    if try_prefix "$p"; then
      break
    fi
  done
fi

if [ -z "${NNG_LIBS}" ]; then
  build_bundled_nng || {
    cat >&2 <<'MSG'
RStataLink2 configure error: could not find or build NNG.

Install libnng development files, set NNG_PREFIX to its installation prefix,
or allow the installer to download and build bundled NNG using cmake.
On Windows with MSYS2 UCRT64, for example, NNG_PREFIX is often /ucrt64.
MSG
    exit 1
  }
fi

MAKE_CMD=${MAKE:-make}
if ! command -v "${MAKE_CMD}" >/dev/null 2>&1; then
  echo "RStataLink2 configure error: make not found" >&2
  exit 1
fi

rm -f "${TARGET}"
if [ "${WINDOWS}" = "1" ]; then
  MAKEFILE="Makefile.win"
else
  MAKEFILE="Makefile"
fi

echo "RStataLink2: compiling ${TARGET}"
"${MAKE_CMD}" -f "${MAKEFILE}" clean >/dev/null 2>&1 || true
"${MAKE_CMD}" -f "${MAKEFILE}" \
  CC="${CC}" \
  CFLAGS="${CFLAGS}" \
  NNG_CFLAGS="${NNG_CFLAGS}" \
  NNG_LIBS="${NNG_LIBS}" \
  TARGET="${TARGET}"

if [ ! -f "${TARGET}" ]; then
  echo "RStataLink2 configure error: ${TARGET} was not produced" >&2
  exit 1
fi

copy_runtime_dlls "${NNG_PREFIX_USED}"

if [ "${RSTATALINK2_KEEP_BUILD:-}" != "1" ]; then
  rm -rf "${BUILD_DIR}" stplugin.c stplugin.h
fi

chmod 755 "${TARGET}" 2>/dev/null || true

echo "RStataLink2: Stata plugin built successfully: inst/stata-plugin/${TARGET}"
exit 0
