import os

import nimterop/build

const
  # Save curl sources in local dir, avoid common location since we make mods
  baseDir* = currentSourcePath.parentDir() / "libcurl"

  # Static build of libcurl only supporting HTTP(s), no other protocols
  cmakeFlags = block:
    var
      cf = "-DHTTP_ONLY=ON -DBUILD_CURL_EXE=OFF -DBUILD_SHARED_LIBS=OFF -DENABLE_MANUAL=OFF -DBUILD_TESTING=OFF"
    when defined(windows):
      cf &= " -DCMAKE_USE_WINSSL=ON"
    cf

# Delete default Makefile to kick off cmake
proc curlPreBuild(outdir, header: string) =
  if fileExists(outdir / "Makefile"):
    rmFile(outdir / "Makefile")

# Download and build libcurl
getHeader(
  header = "curl.h",
  dlurl = "https://curl.haxx.se/download/curl-$1.zip",
  outdir = baseDir,
  cmakeFlags = cmakeFlags
)

# Linker flags for libcurl dependencies
when defined(windows):
  {.passL: "-lws2_32 -lcrypt32".}
elif defined(linux):
  {.passL: linkLibs(@["ssl", "crypto", "ssh2"], false) & " -lz -lpthread".}
