import net, os

import libcurl

import curl, parsecfg, server, utils

when defined(asyncMode):
  import asyncdispatch

when isMainModule:
  setControlCHook(chandler)

  initConfig()

  let
    svr = newHttpServer()
  waitFor svr.serve(Port(8080), curlCallback, gconfig)
  svr.close()
