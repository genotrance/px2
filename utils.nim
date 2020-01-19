import nativesockets, net

const
  DEBUG* = 1
  VERBOSE* = 1

template decho*(args: string) =
  if VERBOSE == 1:
    echo $getThreadId() & ": " & args

proc isClosed*(socket: Socket): bool =
  if socket.getFd() == osInvalidSocket:
    return true
