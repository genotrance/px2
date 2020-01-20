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

  type Callback* = proc(client: HttpClient): Future[void] {.closure, gcsafe.}
else:
  import net

  type Callback* = proc(client: HttpClient) {.closure, gcsafe.}

proc newHttpServer*(reuseAddr = true, reusePort = false): HttpServer =
  new result
  result.reuseAddr = reuseAddr
  result.reusePort = reusePort

proc getHttpCode*(code: int): HttpCode =
  result = parseEnum[HttpCode]("Http" & $code)

proc sendResponse*(client: HttpClient, code: HttpCode) {.async.} =
  await client.socket.send("HTTP/1.1 " & $code & "\c\L")

proc sendError*(client: HttpClient, code: HttpCode) {.async.} =
  await client.socket.send("HTTP/1.1 " & $code & "\c\L" &
                           "Content-Length: " & $(($code).len + 2) & "\c\L\c\L" &
                           $code & "\c\L")

proc sendBuffer*(client: HttpClient, buffer: string) {.async.} =
  await client.socket.send(buffer)

proc sendHeader*(
  client: HttpClient,
  name, value: string
) {.async.} =
  await client.sendBuffer(name & ": " & value & "\c\L")

proc sendHeader*(
  client: HttpClient,
  header: tuple[name, value: string]
) {.async.} =
  await client.sendBuffer(header.name & ": " & header.value & "\c\L")

proc processClient(
  csocket: PxSocket,
  caddress: string,
  callback: Callback
) {.async.} =
  decho "processClient(): " & caddress
  var
    client = new(HttpClient)
    buffer = newStringOfCap(512)
  client.socket = csocket
  client.address = caddress

  while not csocket.isClosed():
    let line = await csocket.recvLine()

    if line.len == 0:
      csocket.close()
      break

    if line != "\r\L":
      buffer &= line & "\r\L"
    else:
      buffer &= line

      client.request = parseRequest(buffer.toSeq())
      if client.request.success():
        await callback(client)
      else:
        await client.sendError(Http400)

      buffer = ""

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
      await processClient(csocket, caddress, callback)
    else:
      server.socket.acceptAddr(csocket, caddress)
      when compileOption("threads"):
        spawn processClient(csocket, caddress, callback)
      else:
        processClient(csocket, caddress, callback)

proc close*(server: HttpServer) =
  server.socket.close()
