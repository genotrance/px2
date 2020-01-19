import nativesockets, net

template decho*(args: string) =
  echo $getThreadId() & ": " & args

proc isClosed*(socket: Socket): bool =
  if socket.getFd() == osInvalidSocket:
    return true
