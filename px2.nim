import net

import curl, server, utils

when defined(asyncMode):
  import asyncdispatch

when isMainModule:
  setControlCHook(chandler)
  let
    svr = newHttpServer()
  waitFor svr.serve(Port(8080), curlCallback)
  svr.close()
