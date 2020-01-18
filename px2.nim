import net

import curl, server

proc startServer() =
  var server = newHttpServer()

  server.serve(Port(8080), curlCb)

when isMainModule:
  startServer()
