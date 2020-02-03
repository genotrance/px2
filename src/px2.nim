import asyncdispatch, net, os

when compileOption("threads"):
  import osproc

import libcurl

import curl, parsecfg, server, utils

proc start(gconfig: ptr GlobalConfig) =
  let
    svr = newHttpServer()
    port = 8080
  decho "Serving on port " & $port
  waitFor svr.serve(Port(port), curlCallback, gconfig)
  svr.close()

when isMainModule:
  setControlCHook(chandler)

  initConfig()

  when compileOption("threads"):
    let
      cores = countProcessors()
    var
      threads = newSeq[Thread[(ptr GlobalConfig)]](cores)
    for i in 0 ..< cores:
      createThread[(ptr GlobalConfig)](threads[i], start, (gconfig))
    joinThreads(threads)
  else:
    start(gconfig)