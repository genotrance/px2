import nativesockets, net, selectors, sequtils, strutils

import httputils, libcurl

import server, utils

const
  PROXY = ""
  INFO_ACTIVESOCKET = (0x500000 + 44).INFO

proc checkCurl(code: Code) =
  if code != E_OK:
    decho $code & ": " & $easy_strerror(code)
#    raise newException(AssertionError, "CURL failed: " & $easy_strerror(code))

proc filterHeaders(headers: string, filter: seq[string]): string =
  # Remove specified headers from string blob
  #
  # First line is the response code
  let
    lines = headers.splitlines()
  for i in 0 ..< lines.len:
    if i != 0 and lines[i].len != 0:
      if lines[i].split(":", maxsplit=1)[0].toLowerAscii() notin filter:
        result &= lines[i] & "\c\L"
    else:
      result &= lines[i] & "\c\L"

proc headerCb(data: ptr char, size: int, nmemb: int, userData: pointer): int {.cdecl.} =
  # Callback that collects response headers and forwards back to client when
  # all have arrived
  var
    client = cast[HttpClient](userData)
    hdrData = newString(size * nmemb)
  copyMem(addr hdrData[0], data, hdrData.len)
  client.headers &= hdrData
  result = hdrData.len.cint

  # If end of headers, send client
  if hdrData == "\c\L":
    # Filter out Transfer-Encoding since libcurl already handles that
    client.headers = filterHeaders(client.headers, @["transfer-encoding"])
    client.response = parseResponse(client.headers.toSeq())
    if client.response.success():
      if client.response.code != 407:
        # Skip sending entire header if part of upstream proxy authentication
        client.sendBuffer(client.headers)
    else:
      client.sendError(Http400)
      result = 0
    client.headers = ""

proc pipeCb(data: ptr char, size: int, nmemb: int, userData: pointer): int {.cdecl.} =
  # Pipe response body back to client - only for non-CONNECT requests
  var
    client = cast[HttpClient](userData)
    buffer = newString(size * nmemb)
  copyMem(addr buffer[0], data, buffer.len)
  client.sendBuffer(buffer)
  result = buffer.len.cint

proc buildHeaderList(r: HttpReqRespHeader): Pslist =
  # Create a curl slist of headers for request
  result = nil
  var
    temp: Pslist = nil
  for name, value in r.headers:
    # Need to null terminate
    var
      header = name & ": " & value
    header.setLen(header.len+1)
    temp = slist_append(result, header)
    doAssert not temp.isNil, "Nilled out"
    result = temp

# Debug output

proc printHeaders(r: HttpReqRespHeader, prefix: string) =
  for name, value in r.headers:
    decho "  " & prefix & " " & name & " = " & value

proc printRequest(client: HttpClient) =
  let r = client.request
  decho "  " & $r.meth & " " & r.uri() & " " & $r.version
  printHeaders(r, "=>")

proc printResponse(client: HttpClient) =
  let r = client.response
  decho "  " & $r.version & " " & $r.code
  printHeaders(r, "<=")

proc curlGet*(client: HttpClient) =
  # Handle all non-CONNECT requests
  var
    c = easy_init()
  decho "curlGet()"
  printRequest(client)

  checkCurl c.easy_setopt(OPT_URL, client.request.getUri())
  let
    headers = buildHeaderList(client.request)
  checkCurl c.easy_setopt(OPT_HTTPHEADER, headers)

  checkCurl c.easy_setopt(OPT_NOPROGRESS, true);
  if PROXY.len != 0:
    checkCurl c.easy_setopt(OPT_PROXY, PROXY)
    checkCurl c.easy_setopt(OPT_PROXYAUTH, AUTH_NTLM)
    checkCurl c.easy_setopt(OPT_PROXYUSERPWD, ":")
  if DEBUG == 1:
    checkCurl c.easy_setopt(OPT_VERBOSE, 1)

  # Callbacks will handle communication of response back to client
  checkCurl c.easy_setopt(OPT_HEADERFUNCTION, headerCb)
  checkCurl c.easy_setopt(OPT_HEADERDATA, client)
  checkCurl c.easy_setopt(OPT_WRITEFUNCTION, pipeCb)
  checkCurl c.easy_setopt(OPT_WRITEDATA, client)

  checkCurl c.easy_perform()

  slist_free_all(headers)
  c.easy_cleanup()

  printResponse(client)

  # Close client socket if there's no content-length info
  let cl = client.response["content-length"]
  if cl.len == 0 or cl == "0":
    client.socket.close()

  decho "curlGet() done"

proc curlConnect*(client: HttpClient) =
  # Handle all CONNECT requests
  var
    c = easy_init()
    ssocketH, csocketH: SocketHandle
    socket: net.Socket
    selector = newSelector[SocketHandle]()
    cl = 0

  decho "curlConnect()"
  printRequest(client)

  checkCurl c.easy_setopt(OPT_URL, client.request.getUri())
  let
    headers = buildHeaderList(client.request)
  checkCurl c.easy_setopt(OPT_HTTPHEADER, headers)
  checkCurl c.easy_setopt(OPT_NOPROGRESS, true);
  if PROXY.len != 0:
    checkCurl c.easy_setopt(OPT_PROXY, PROXY)
    checkCurl c.easy_setopt(OPT_HTTPPROXYTUNNEL, 1)
    checkCurl c.easy_setopt(OPT_PROXYAUTH, AUTH_NTLM)
    checkCurl c.easy_setopt(OPT_PROXYUSERPWD, ":")
  # Connect only so that we can use socket for communication
  checkCurl c.easy_setopt(OPT_CONNECT_ONLY, 1)

  # Callback will only handle communication of headers back to client
  checkCurl c.easy_setopt(OPT_HEADERFUNCTION, headerCb)
  checkCurl c.easy_setopt(OPT_HEADERDATA, client)

  checkCurl c.easy_perform()

  printResponse(client)

  # Send successful connect if no upstream proxy
  if PROXY.len == 0:
    client.sendBuffer("HTTP/1.1 200 Connection established\c\L")
    client.sendBuffer("Proxy-Agent: px2\c\L\c\L")
  if DEBUG == 1:
    checkCurl c.easy_setopt(OPT_VERBOSE, 1)

  # Get curl socket to bridge client <-> upstream
  checkCurl c.easy_getinfo(INFO_ACTIVESOCKET, addr ssocketH)
  if ssocketH != osInvalidSocket:
    socket = newSocket(ssocketH)
    csocketH = getFd(client.socket)

    # Set to non-blocking to enable selector to work
    ssocketH.setBlocking(false)
    csocketH.setBlocking(false)

    # Register both sockets for Read/Write - bidirectional
    registerHandle(selector, ssocketH, {Event.Read, Event.Write}, 0.SocketHandle)
    registerHandle(selector, csocketH, {Event.Read, Event.Write}, 0.SocketHandle)

    var
      sdata, cdata: seq[string]
      data = ""
      done = false
    while true:
      var
        rks = select(selector, 100)
      if rks.len == 0 or (done and sdata.len == 0 and cdata.len == 0):
        # Close if nothing to do
        client.socket.close()
        break
      for rk in rks:
        # First read all data from both sockets
        if Event.Read in rk.events:
          if rk.fd == ssocketH.int:
            data = socket.recv(4096)
            if data.len != 0:
              cl += data.len
              cdata.add data
            else:
              decho "Connection closed by proxy"
              unregister(selector, ssocketH)
              ssocketH.close()
              sdata = @[]
              done = true
          elif rk.fd == csocketH.int:
            data = client.socket.recv(4096)
            if data.len != 0:
              cl += data.len
              sdata.add data
            else:
              decho "Connection closed by client"
              unregister(selector, csocketH)
              csocketH.close()
              cdata = @[]
              done = true

      for rk in rks:
        # Write any pending data to target sockets
        if Event.Write in rk.events:
          if rk.fd == ssocketH.int:
            if sdata.len != 0:
              socket.send(sdata[0])
              sdata.delete(0)
          elif rk.fd == csocketH.int:
            if cdata.len != 0:
              client.socket.send(cdata[0])
              cdata.delete(0)
  else:
    decho "Connection closed by proxy prematurely"

  slist_free_all(headers)
  c.easy_cleanup()

  decho "curlConnect(): done " & $cl

proc curlCb*(client: HttpClient) =
  # Main callback to handle requests
  if client.request.meth == MethodConnect:
    curlConnect(client)
  else:
    curlGet(client)
