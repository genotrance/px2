import sequtils, strutils

when compileOption("threads"):
  import threadpool

import httputils

import utils

type
  HttpServer* = ref object
    socket: PxSocket
    reuseAddr: bool
    reusePort: bool

  HttpClient* = ref object
    socket*: PxSocket
    address*: string
    request*: HttpRequestHeader
    headers*: string
    response*: HttpResponseHeader

when defined(asyncMode):
  import asyncdispatch, asyncnet

  type
    Callback* = proc(clt: Client): Future[void] {.closure, gcsafe.}
    Client* = FutureVar[HttpClient]

  template client*(): HttpClient = clt.mget()
else:
  import net

  type
    Callback* = proc(clt: Client) {.closure, gcsafe.}
    Client* = HttpClient

  template client*(): HttpClient = clt

proc newHttpServer*(reuseAddr = true, reusePort = false): HttpServer =
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
  csocket: PxSocket,
  caddress: string,
  callback: Callback
) {.async.} =
  decho "processClient(): " & caddress
  when defined(asyncMode):
    var
      clt = newFutureVar[HttpClient]("server.processClient()")
      buffer = newFutureVar[string]("server.processClient()")
  else:
    var
      clt: HttpClient
      buffer: string
  client = new(HttpClient)
  client.socket = csocket
  client.address = caddress
  buffer.mget() = newStringOfCap(512)

  while not csocket.isClosed():
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

  decho "processClient() done"

proc serve*(
  server: HttpServer,
  port: Port,
  callback: Callback,
  address = ""
) {.async.} =
  server.socket = newPxSocket()
  if server.reuseAddr:
    server.socket.setSockOpt(OptReuseAddr, true)
  if server.reusePort:
    server.socket.setSockOpt(OptReusePort, true)
  server.socket.bindAddr(port, address)
  server.socket.listen()

  while true:
    var
      csocket: PxSocket
      caddress = ""
    when defined(asyncMode):
      (caddress, csocket) = await server.socket.acceptAddr()
      asyncCheck processClient(csocket, caddress, callback)
    else:
      server.socket.acceptAddr(csocket, caddress)
      when compileOption("threads"):
        spawn processClient(csocket, caddress, callback)
      else:
        processClient(csocket, caddress, callback)

proc close*(server: HttpServer) =
  server.socket.close()
