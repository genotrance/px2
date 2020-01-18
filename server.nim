import net, sequtils, strutils, threadpool

import httputils

type
  HttpServer* = ref object
    socket: Socket
    reuseAddr: bool
    reusePort: bool

  HttpClient* = ref object
    socket*: Socket
    address*: string
    request*: HttpRequestHeader
    headers*: string
    response*: HttpResponseHeader

proc newHttpServer*(reuseAddr = true, reusePort = false): HttpServer =
  new result
  result.reuseAddr = reuseAddr
  result.reusePort = reusePort

proc getHttpCode*(code: int): HttpCode =
  result = parseEnum[HttpCode]("Http" & $code)

proc sendResponse*(client: HttpClient, code: HttpCode) =
  client.socket.send("HTTP/1.1 " & $code & "\c\L")

proc sendError*(client: HttpClient, code: HttpCode) =
  client.socket.send("HTTP/1.1 " & $code & "\c\L" &
                          "Content-Length: " & $(($code).len + 2) & "\c\L\c\L" &
                          $code & "\c\L")

proc sendBuffer*(client: HttpClient, buffer: string) =
  client.socket.send(buffer)

proc sendHeader*(
  client: HttpClient,
  name, value: string
) =
  client.sendBuffer(name & ": " & value & "\c\L")

proc sendHeader*(
  client: HttpClient,
  header: tuple[name, value: string]
) =
  client.sendBuffer(header.name & ": " & header.value & "\c\L")

proc processClient(
  server: HttpServer,
  socket: Socket,
  address: string,
  callback: proc (client: HttpClient) {.closure, gcsafe.}
) =
  var
    client = new(HttpClient)
    buffer = newStringOfCap(512)
  client.socket = socket
  client.address = address

  while true:
    let line = socket.recvLine()

    if line.len == 0:
      socket.close()
      return

    if line == "\r\L":
      buffer &= line
      break
    buffer &= line & "\r\L"
  if buffer.len != 0:
    client.request = parseRequest(buffer.toSeq())
    if client.request.success():
      callback(client)
    else:
      client.sendError(Http400)

proc serve*(
  server: HttpServer,
  port: Port,
  callback: proc (client: HttpClient) {.closure, gcsafe.},
  address = ""
) =
  server.socket = newSocket()
  if server.reuseAddr:
    server.socket.setSockOpt(OptReuseAddr, true)
  if server.reusePort:
    server.socket.setSockOpt(OptReusePort, true)
  server.socket.bindAddr(port, address)
  server.socket.listen()

  while true:
    var
      socket: Socket
      address = ""
    server.socket.acceptAddr(socket, address)
    spawn processClient(server, socket, address, callback)

proc close*(server: HttpServer) =
  server.socket.close()


