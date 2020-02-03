import asyncdispatch, asyncnet, sequtils, strutils

import httputils

import parsecfg, utils

type
  HttpServer* = ref object
    socket: AsyncSocket
    reuseAddr: bool
    reusePort: bool

  HttpClient* = ref object
    socket*: AsyncSocket
    address*: string
    request*: HttpRequestHeader
    headers*: string
    response*: HttpResponseHeader
    gconfig*: ptr GlobalConfig

type
  Callback* = proc(clt: Client): Future[void] {.closure, gcsafe.}
  Client* = FutureVar[HttpClient]

template client*(): HttpClient = clt.mget()

proc newHttpServer*(reuseAddr = true, reusePort = true): HttpServer =
  new result
  result.reuseAddr = reuseAddr
  result.reusePort = reusePort

proc getHttpCode*(code: int): HttpCode =
  result = parseEnum[HttpCode]("Http" & $code)

proc sendResponse*(clt: Client, code: HttpCode) {.async.} =
  await client.socket.send("HTTP/1.1 " & $code & "\c\L")

proc sendError*(clt: Client, code: HttpCode) {.async.} =
  await client.socket.send("HTTP/1.1 " & $code & "\c\L" &
                           "Content-Length: " & $(($code).len + 2) & "\c\L\c\L" &
                           $code & "\c\L")

proc sendBuffer*(clt: Client, buffer: string) {.async.} =
  await client.socket.send(buffer)

proc sendHeader*(
  clt: Client,
  name, value: string
) {.async.} =
  await clt.sendBuffer(name & ": " & value & "\c\L")

proc sendHeader*(
  clt: Client,
  header: tuple[name, value: string]
) {.async.} =
  await clt.sendBuffer(header.name & ": " & header.value & "\c\L")

proc processClient(
  csocket: AsyncSocket,
  caddress: string,
  callback: Callback,
  gconfig: ptr GlobalConfig
) {.async.} =
  decho "processClient(): " & caddress
  var
    clt = newFutureVar[HttpClient]("server.processClient()")
    buffer = newFutureVar[string]("server.processClient()")

  client = new(HttpClient)
  client.socket = csocket
  client.address = caddress
  client.gconfig = gconfig
  buffer.mget() = newStringOfCap(512)

  while not csocket.isClosed():
    try:
      let line = await csocket.recvLine()

      if line.len == 0:
        csocket.close()
        break

      if line != "\r\L":
        buffer.mget() &= line & "\r\L"
      else:
        buffer.mget() &= line

        client.request = parseRequest(buffer.mget().toSeq())
        if client.request.success():
          await callback(clt)
        else:
          await clt.sendError(Http400)

        buffer.mget() = ""
    except Exception as e:
      decho "Failed processClient(): " & e.msg
      break

  decho "processClient() done"

proc serve*(
  server: HttpServer,
  port: Port,
  callback: Callback,
  gconfig: ptr GlobalConfig,
  address = ""
) {.async.} =
  try:
    server.socket = newAsyncSocket(buffered = false)
    if server.reuseAddr:
      server.socket.setSockOpt(OptReuseAddr, true)
    if server.reusePort:
      server.socket.setSockOpt(OptReusePort, true)
    server.socket.bindAddr(port, address)
    server.socket.listen()
  except Exception as e:
    decho "Failed serve(): " & e.msg
    return

  while true:
    try:
      var
        (caddress, csocket) = await server.socket.acceptAddr()
      asyncCheck processClient(csocket, caddress, callback, gconfig)
    except Exception as e:
      decho "Failed serve() loop: " & e.msg
      continue

proc close*(server: HttpServer) =
  server.socket.close()
