import nativesockets, net, strutils

import httputils

const
  DEBUG* = 1
  VERBOSE* = 1

template decho*(args: string) =
  if VERBOSE == 1:
    when compileOption("threads"):
      echo $getThreadId() & ": " & args
    else:
      echo args

proc isClosed*(socket: Socket): bool =
  if socket.getFd() == osInvalidSocket:
    return true

proc getUri*(r: HttpRequestHeader): string =
  # Need to null terminate uri()
  result = (r.uri() & " ").strip()
