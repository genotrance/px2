import os

import nimterop/build

const
  baseDir = getProjectCacheDir("libcurl")
  cmakeFlags = block:
    var
      cf = "-DHTTP_ONLY=ON -DBUILD_CURL_EXE=OFF -DBUILD_SHARED_LIBS=OFF -DENABLE_MANUAL=OFF -DBUILD_TESTING=OFF"
    when defined(windows):
      cf &= " -DCMAKE_USE_WINSSL=ON"
    cf

proc curlPreBuild(outdir, header: string) =
  if fileExists(outdir / "Makefile"):
    rmFile(outdir / "Makefile")

getHeader(
  header = "curl.h",
  dlurl = "https://curl.haxx.se/download/curl-$1.zip",
  outdir = baseDir,
  cmakeFlags = cmakeFlags
)

when defined(windows):
  {.passL: "-lws2_32 -lcrypt32".}