# Package

version       = "0.1.0"
author        = "genotrance"
description   = "An HTTP proxy server to automatically authenticate through upstream proxies"
license       = "MIT"
srcDir        = "src"
bin           = @["px2"]

# Dependencies

requires "nim >= 1.0.4"

requires "httputils >= 0.2.0"
requires "libcurl >= 1.0.0"
requires "nimterop >= 0.4.4"

task test, "Test px2":
  exec "nim c src/px2"
  exec "nim c --threads:on src/px2"
  exec "nim c -d:asyncMode src/px2"
