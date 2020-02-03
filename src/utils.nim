import asyncdispatch, nativesockets, net, os

import httputils

var
  silentMode* = false
  verboseMode* = false

template decho*(args: string) =
  if not silentMode:
    when compileOption("threads"):
      echo $getThreadId() & ": " & args
    else:
      echo args

template ddecho*(args: string) =
  if verboseMode:
    decho(args)

template dddecho*(args: string) =
  if verboseMode:
    stdout.write(" " & args)

var
  counter = 0
template ddd*() =
  counter += 1
  dddecho($counter)

proc isClosed*(socket: Socket): bool =
  if socket.getFd() == osInvalidSocket:
    return true

proc chandler*() {.noconv.} =
  when compileOption("threads"):
    setupForeignThreadGc()
  quit(0)
