import nativesockets, net, selectors, sequtils, strutils

when defined(asyncMode):
  import asyncnet, asyncdispatch

import httputils, libcurl

import server, parsecfg, utils

const
  BUFFER_SIZE = 16 * 1024

  # Values not yet in libcurl wrapper
  INFO_ACTIVESOCKET = (0x500000 + 44).INFO

  OPTTYPE_LONG = 0
  OPTTYPE_OBJECTPOINT = 10000
  OPTTYPE_STRINGPOINT = OPTTYPE_OBJECTPOINT

  OPT_NOPROXY = (OPTTYPE_OBJECTPOINT + 177).Option
  OPT_TCP_FASTOPEN = (OPTTYPE_LONG + 244).Option
  OPT_PRE_PROXY = (OPTTYPE_STRINGPOINT + 262).Option

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

proc headerCallback(data: ptr char, size: int, nmemb: int, userData: pointer): int {.cdecl.} =
  # Callback that collects response headers and forwards back to client when
  # all have arrived
  var
    clt = cast[Client](userData)
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
        waitFor clt.sendBuffer(client.headers)
    else:
      waitFor clt.sendError(Http400)
      result = 0
    client.headers = ""

proc writeCallback(data: ptr char, size: int, nmemb: int, userData: pointer): int {.cdecl.} =
  # Pipe response body back to client - only for non-CONNECT requests
  var
    clt = cast[Client](userData)
    buffer = newString(size * nmemb)
  copyMem(addr buffer[0], data, buffer.len)
  waitFor clt.sendBuffer(buffer)
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
    temp = slist_append(result, header)
    doAssert not temp.isNil, "Nilled out"
    result = temp

# Debug output

proc printHeaders(r: HttpReqRespHeader, prefix: string) =
  for name, value in r.headers:
    decho "  " & prefix & " " & name & " = " & value

proc printRequest(clt: Client) =
  let r = client.request
  decho "  " & $r.meth & " " & r.uri() & " " & $r.version
  printHeaders(r, "=>")

proc printResponse(clt: Client) =
  let r = client.response
  decho "  " & $r.version & " " & $r.code
  printHeaders(r, "<=")

proc curlSetup*(clt: Client, c: PCurl) {.async.} =
  # Setup libcurl based on configuration
  let
    cfg = client.gconfig.first

  if not cfg.tcp_nodelay:
    checkCurl c.easy_setopt(OPT_TCP_NODELAY, 0)

  if cfg.tcp_fastopen:
    checkCurl c.easy_setopt(OPT_TCP_FASTOPEN, 1)

  if cfg.recvpersecond != 0 and cfg.recvpersecond < BUFFER_SIZE:
    checkCurl c.easy_setopt(OPT_BUFFER_SIZE, cfg.recvpersecond)
  else:
    checkCurl c.easy_setopt(OPT_BUFFER_SIZE, BUFFER_SIZE)

  if cfg.proxy.len != 0:
    checkCurl c.easy_setopt(OPT_PROXY, cfg.proxy)
    checkCurl c.easy_setopt(OPT_PROXYTYPE, cfg.proxyver)

  checkCurl c.easy_setopt(OPT_PROXYUSERPWD, cfg.proxyuserpwd)

  if cfg.preproxy.len != 0:
    checkCurl c.easy_setopt(OPT_PRE_PROXY, cfg.preproxy)

  if cfg.proxyanyauth:
    checkCurl c.easy_setopt(OPT_PROXYAUTH, AUTH_ANY)
  elif cfg.proxynegotiate:
    checkCurl c.easy_setopt(OPT_PROXYAUTH, AUTH_GSSNEGOTIATE)
  elif cfg.proxyntlm:
    checkCurl c.easy_setopt(OPT_PROXYAUTH, AUTH_NTLM)
  elif cfg.proxydigest:
    checkCurl c.easy_setopt(OPT_PROXYAUTH, AUTH_DIGEST)
  elif cfg.proxybasic:
    checkCurl c.easy_setopt(OPT_PROXYAUTH, AUTH_BASIC)

  checkCurl c.easy_setopt(OPT_NOPROXY, cfg.noproxy)

  if verboseMode:
    checkCurl c.easy_setopt(OPT_VERBOSE, 1)

  checkCurl c.easy_setopt(OPT_NOPROGRESS, true);

proc curlGet*(clt: Client) {.async.} =
  # Handle all non-CONNECT requests
  var
    c = easy_init()
  decho "curlGet()"
  printRequest(clt)

  await curlSetup(clt, c)

  checkCurl c.easy_setopt(OPT_URL, client.request.uri())
  let
    headers = buildHeaderList(client.request)
  checkCurl c.easy_setopt(OPT_HTTPHEADER, headers)

  # Callbacks will handle communication of response back to client
  checkCurl c.easy_setopt(OPT_HEADERFUNCTION, headerCallback)
  checkCurl c.easy_setopt(OPT_HEADERDATA, clt)
  checkCurl c.easy_setopt(OPT_WRITEFUNCTION, writeCallback)
  checkCurl c.easy_setopt(OPT_WRITEDATA, clt)

  checkCurl c.easy_perform()

  slist_free_all(headers)
  c.easy_cleanup()

  printResponse(clt)

  # Close client socket if there's no content-length info
  let cl = client.response["content-length"]
  if cl.len == 0 or cl == "0":
    client.socket.close()

  decho "curlGet() done"

proc curlConnect*(clt: Client) {.async.} =
  # Handle all CONNECT requests
  var
    c = easy_init()
    ssocketH, csocketH: SocketHandle
    socket: net.Socket
    selector = newSelector[SocketHandle]()
    cl = 0

  decho "curlConnect()"
  printRequest(clt)

  await curlSetup(clt, c)

  checkCurl c.easy_setopt(OPT_URL, client.request.uri())
  let
    headers = buildHeaderList(client.request)
    proxy = client.gconfig.first.proxy
  checkCurl c.easy_setopt(OPT_HTTPHEADER, headers)
  checkCurl c.easy_setopt(OPT_NOPROGRESS, true);
  if proxy.len != 0:
    checkCurl c.easy_setopt(OPT_HTTPPROXYTUNNEL, 1)
  # Connect only so that we can use socket for communication
  checkCurl c.easy_setopt(OPT_CONNECT_ONLY, 1)

  # Callback will only handle communication of headers back to client
  checkCurl c.easy_setopt(OPT_HEADERFUNCTION, headerCallback)
  checkCurl c.easy_setopt(OPT_HEADERDATA, clt)

  checkCurl c.easy_perform()

  # Send successful connect if no upstream proxy
  if proxy.len == 0:
    await clt.sendBuffer("HTTP/1.1 200 Connection established\c\L" &
                            "Proxy-Agent: px2\c\L\c\L")
    decho "  Tunnel established"
  else:
    printResponse(clt)
  if verboseMode:
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
      when defined(asyncMode):
        await sleepAsync(0)

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
            while true:
              data = socket.recv(BUFFER_SIZE)
              if data.len != 0:
                ddecho "    " & $data.len & " <= server"
                cl += data.len
                cdata.add data
              else:
                decho "Connection closed by proxy"
                unregister(selector, ssocketH)
                ssocketH.close()
                sdata = @[]
                done = true
              if data.len < BUFFER_SIZE:
                break
          elif rk.fd == csocketH.int:
            while true:
              data = await client.socket.recv(BUFFER_SIZE)
              if data.len != 0:
                ddecho "    " & $data.len & " <= client"
                cl += data.len
                sdata.add data
              else:
                decho "Connection closed by client"
                unregister(selector, csocketH)
                csocketH.close()
                cdata = @[]
                done = true
              if data.len < BUFFER_SIZE:
                break
  
      for rk in rks:
        # Write any pending data to target sockets
        if Event.Write in rk.events:
          if rk.fd == ssocketH.int:
            while sdata.len != 0:
              socket.send(sdata[0])
              ddecho "    " & $sdata[0].len & " => server"
              sdata.delete(0)
          elif rk.fd == csocketH.int:
            while cdata.len != 0:
              await client.socket.send(cdata[0])
              ddecho "    " & $cdata[0].len & " => client"
              cdata.delete(0)
  else:
    decho "Connection closed by proxy prematurely"

  slist_free_all(headers)
  c.easy_cleanup()

  decho "curlConnect(): done " & $cl

proc curlCallback*(clt: Client) {.async.} =
  # Main callback to handle requests
  if client.request.meth == MethodConnect:
    await curlConnect(clt)
  else:
    await curlGet(clt)
