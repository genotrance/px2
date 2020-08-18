# Package

version       = "0.1.0"
author        = "genotrance"
description   = "An HTTP proxy server to automatically authenticate through upstream proxies"
license       = "MIT"
srcDir        = "src"
bin           = @["px2"]

# Dependencies

requires "nim >= 1.0.6"

requires "httputils >= 0.2.0"
requires "libcurl >= 1.0.0"
requires "nimterop >= 0.6.8"
