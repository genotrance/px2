import nativesockets, net, selectors, sequtils, posix

import httputils, libcurl

import server

const
  PROXY = "localhost:8888"
  INFO_ACTIVESOCKET = (0x500000 + 44).INFO
  OPT_SUPPRESS_CONNECT_HEADERS = 265.Option

proc checkCurl(code: Code) =
  if code != E_OK:
    echo $code & ": " & $easy_strerror(code)
#    raise newException(AssertionError, "CURL failed: " & $easy_strerror(code))

proc headerCb(data: ptr char, size: cint, nmemb: cint, userData: pointer): cint =
  var
    client = cast[HttpClient](userData)
    hdrData = newString(size * nmemb)
  copyMem(addr hdrData[0], data, hdrData.len)
  client.headers &= hdrData
  result = hdrData.len.cint
  if hdrData == "\c\L":
    client.response = parseResponse(client.headers.toSeq())
    if client.response.success():
      client.sendBuffer(client.headers)
    else:
      client.sendError(Http400)
      result = 0

proc pipeCb(data: ptr char, size: cint, nmemb: cint, userData: pointer): cint =
  var
    client = cast[HttpClient](userData)
    buffer = newString(size * nmemb)
  copyMem(addr buffer[0], data, buffer.len)
  client.sendBuffer(buffer)
  result = buffer.len.cint

proc buildHeaderList(r: HttpReqRespHeader): Pslist =
  for name, value in r.headers:
    echo "  Sending " & name & " = " & value
    result = slist_append(result, (name & ": " & value).cstring)

proc curlGet*(client: HttpClient) =
  var
    c = easy_init()
    url = client.request.uri()

  echo "Proxying " & url
  checkCurl c.easy_setopt(OPT_URL, url)
  let
    headers = buildHeaderList(client.request)
  checkCurl c.easy_setopt(OPT_HTTPHEADER, headers)

  checkCurl c.easy_setopt(OPT_NOPROGRESS, true);
  checkCurl c.easy_setopt(OPT_PROXY, PROXY)

  checkCurl c.easy_setopt(OPT_HEADERFUNCTION, headerCb)
  checkCurl c.easy_setopt(OPT_HEADERDATA, client)
  checkCurl c.easy_setopt(OPT_WRITEFUNCTION, pipeCb)
  checkCurl c.easy_setopt(OPT_WRITEDATA, client)

  checkCurl c.easy_perform()

  slist_free_all(headers)
  c.easy_cleanup()

  let cl = client.response["content-length"]
  if cl.len == 0 or cl == "0":
    client.socket.close()

proc curlConnect*(client: HttpClient) =
  var
    c = easy_init()
    url = client.request.uri()
    ssocketH, csocketH: SocketHandle
    socket: net.Socket
    selector = newSelector[SocketHandle]()

  echo "Tunneling " & url
  checkCurl c.easy_setopt(OPT_URL, url)
  let
    headers = buildHeaderList(client.request)
  checkCurl c.easy_setopt(OPT_HTTPHEADER, headers)
  checkCurl c.easy_setopt(OPT_NOPROGRESS, true);
  if PROXY.len != 0:
    checkCurl c.easy_setopt(OPT_PROXY, PROXY)
    checkCurl c.easy_setopt(OPT_HTTPPROXYTUNNEL, 1)
  checkCurl c.easy_setopt(OPT_CONNECT_ONLY, 1)

  checkCurl c.easy_setopt(OPT_HEADERFUNCTION, headerCb)
  checkCurl c.easy_setopt(OPT_HEADERDATA, client)

  checkCurl c.easy_perform()

  if PROXY.len == 0:
    client.sendBuffer("HTTP/1.1 200 Connection established\c\L")
    client.sendBuffer("Proxy-Agent: px2\c\L\c\L")

  checkCurl c.easy_getinfo(INFO_ACTIVESOCKET, addr ssocketH)
  socket = newSocket(ssocketH)

  csocketH = getFd(client.socket)

  registerHandle(selector, ssocketH, {Event.Read, Event.Write}, 0.SocketHandle)
  registerHandle(selector, csocketH, {Event.Read, Event.Write}, 0.SocketHandle)

  var
    sdata, cdata: seq[string]
    data = ""
    cl = 0
    done = false
  while true:
    var
      rks = select(selector, 100)
    if rks.len == 0 or (done and sdata.len == 0 and cdata.len == 0):
      client.socket.close()
      break
    for rk in rks:
      if Event.Read in rk.events:
        if rk.fd == ssocketH.int:
          data = socket.recv(4096)
          if data.len != 0:
            cl += data.len
            cdata.add data
            # if data[^1] != '\L':
            #   cl += 2
            #   cdata[^1] &= "\c\L"
            echo "-> " & cdata[^1]
          else:
            echo "Connection closed by proxy"
            unregister(selector, ssocketH)
            ssocketH.close()
            sdata = @[]
            done = true
        elif rk.fd == csocketH.int:
          data = client.socket.recv(4096)
          if data.len != 0:
            cl += data.len
            sdata.add data
            # if data[^1] != '\L':
            #   cl += 2
            #   sdata[^1] &= "\c\L"
            echo "<- " & sdata[^1]
          else:
            echo "Connection closed by client"
            unregister(selector, csocketH)
            csocketH.close()
            cdata = @[]
            done = true

    for rk in rks:
      if Event.Write in rk.events:
        if rk.fd == ssocketH.int:
          if sdata.len != 0:
            socket.send(sdata[0])
            sdata.delete(0)
        elif rk.fd == csocketH.int:
          if cdata.len != 0:
            client.socket.send(cdata[0])
            cdata.delete(0)

  slist_free_all(headers)
  c.easy_cleanup()

proc curlCb*(client: HttpClient) =
  if client.request.meth == MethodConnect:
    curlConnect(client)
  else:
    curlGet(client)
