import os, strutils

import libcurl

import nimterop/[build, cimport]

import utils

# Need baseDir and ensure libcurl is built before this module is loaded
import curlwrap

# Include directories for parsecfg
cIncludeDir(baseDir / "include")
cIncludeDir(baseDir / "lib")
cIncludeDir(baseDir / "buildcache" / "lib")

# Use config.h created for libcurl build
cDefine("HAVE_CONFIG_H")

# Skip reimport few include files that cause build failures
cDefine("CURLINC_EASY_H")
cDefine("CURLINC_TYPECHECK_GCC_H")

const
  src = baseDir / "src"
  inc = baseDir / "include"
  cfgable = src / "tool_cfgable.h"
  curlh = inc / "curl" / "curl.h"

proc backup(file: string): bool =
  let
    back = file & "~"
  if not fileExists(back):
    cpFile(file, back)
    result = true

static:
  # Work around tools_cfgable.h forward declaration
  if backup(cfgable):
    writeFile(cfgable,
              readFile(cfgable).
              replace("struct GlobalConfig;", "//struct GlobalConfig;"))

  # Work around reimport of non-CDECL procs - comment all extern func prototypes
  if backup(curlh):
    var
      curlhDataOut = ""
      start = false
    for line in readFile(curlh).splitLines():
      if line.startsWith("CURL_EXTERN"):
        curlhDataOut &= "/*"
        start = true

      curlhDataOut &= line

      if start and ");" in line:
        curlhDataOut &= "*/"
        start = false

      curlhDataOut &= "\n"

    curlh.writeFile(curlhDataOut)

cOverride:
  type
    curl_off_t* = int
    trace* = int

# Import parsecfg objects
cImport(src / "tool_cfgable.h", flags = "-s")

# Import proc parseconfig()
cImport(src / "tool_parsecfg.h")

# Import proc parse_args()
static:
  cDebug()
  cSkipSymbol(@["GlobalConfig", "OperationConfig", "getparameter"])
cImport(src / "tool_getparam.h")
proc parse_args*(gconfig: ptr GlobalConfig, argc: cint, argv: ptr cstring):
  ParameterError {.importc, cdecl.}

# Import proc tool_help()
cImport(src / "tool_help.h")

# Import proc get_libcurl_info()
var
  curlinfo* {.importc, header: src / "tool_libinfo.h".}: PVersion_info_data
#proc get_libcurl_info*(): Code {.importc.}

# Compile in all parsecfg related curl code
cCompile(src / "tool_cfgable.c")
cCompile(src / "tool_filetime.c")
cCompile(src / "tool_formparse.c")
cCompile(src / "tool_getparam.c")
cCompile(src / "tool_getpass.c")
cCompile(src / "tool_help.c")
cCompile(src / "tool_helpers.c")
cCompile(src / "tool_homedir.c")
cCompile(src / "tool_libinfo.c")
cCompile(src / "tool_msgs.c")
cCompile(src / "tool_paramhlp.c")
cCompile(src / "tool_parsecfg.c")

# Create new GlobalConfig object
#
# From src/tool_main.c:main_init()
template initConfig*() {.dirty.} =
  var
    gconfig: GlobalConfig
    config: OperationConfig

  # Set errors to stderr
  gconfig.errors = cast[ptr File](stderr)

  # Global init
  doAssert global_init(GLOBAL_DEFAULT) == E_OK

  # Load libcurl info
  curlinfo = version_info(VERSION_NOW)

  gconfig.first = addr config
  gconfig.last = addr config

  config_init(gconfig.first)
  gconfig.first.global = addr gconfig

  # Parse command line params
  var
    params = commandLineParams()
    plen = params.len
  if plen != 0:
    var
      args: array[64, cstring]
    args[0] = "".cstring
    for i in 0 ..< plen:
      args[i+1] = params[i].cstring

    let
      res = parse_args(addr gconfig, (plen+1).cint,
                        cast[ptr cstring](addr args))

    if res == PARAM_HELP_REQUESTED:
      tool_help()
      quit(0)
    elif res == PARAM_VERSION_INFO_REQUESTED:
      echo version()
      quit(0)
    elif res > 0:
      quit(res.int)

  silentMode = gconfig.mute
  verboseMode = gconfig.tracetype != 0.trace

when isMainModule:
  initConfig()

  echo gconfig.first.proxy
