import nativesockets, net, os

import httputils

when defined(asyncMode):
  import asyncdispatch, asyncnet

  type PxSocket* = AsyncSocket

  template newPxSocket*(): PxSocket = newAsyncSocket(buffered = false)
else:
  import net

  type PxSocket* = Socket

  template newPxSocket*(): PxSocket = newSocket()

  macro async*(code: untyped): untyped = code
  macro asyncCheck*(code: untyped): untyped = code
  macro await*(code: untyped): untyped = code
  macro mget*(code: untyped): untyped = code
  macro waitFor*(code: untyped) = code

const
  DEBUG* = 0
  VERBOSE* = 1

template decho*(args: string) =
  when VERBOSE == 1:
    when compileOption("threads"):
      echo $getThreadId() & ": " & args
    else:
      echo args

template ddecho*(args: string) =
  when DEBUG == 1:
    decho(args)

template dddecho*(args: string) =
  when DEBUG == 1:
    stdout.write(" " & args)

var
  counter = 0
template ddd*() =
  counter += 1
  dddecho($counter)

proc isClosed*(socket: Socket): bool =
  if socket.getFd() == osInvalidSocket:
    return true

proc getUri*(r: HttpRequestHeader): string =
  # Need to null terminate uri()
  result = r.uri()
  result.setLen(result.len+1)

proc chandler*() {.noconv.} =
  when compileOption("threads"):
    setupForeignThreadGc()
  quit(0)
