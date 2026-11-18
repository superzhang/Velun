import os,json,threading,socket,time,base64,html,urllib.parse
from pathlib import Path
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import FTPHandler
from pyftpdlib.servers import FTPServer
import paramiko
import argparse,tempfile
args=argparse.ArgumentParser(description="Local-only protocol test servers; stop with Ctrl-C")
args.add_argument("--media",required=True,help="An existing MKV fixture with duration over 10 seconds")
args.add_argument("--work-dir",default=tempfile.mkdtemp(prefix="luma-protocol-tests-"))
options=args.parse_args()
ROOT=Path(options.work_dir).resolve();ROOT.mkdir(exist_ok=True)
DATA=Path(options.media).read_bytes()
(ROOT/'Fixture.S01E01.mkv').write_bytes(DATA)
USER='fixture';PASSWORD='local-test-only';TOKEN='fixture-token'
class HTTP(BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def send(self,data,typ='application/json',code=200):
  if isinstance(data,str):data=data.encode()
  self.send_response(code);self.send_header('Content-Type',typ);self.send_header('Content-Length',len(data));self.end_headers()
  if self.command!='HEAD':self.wfile.write(data)
 def authorized(self,path):
  if path.startswith('/dav'):return self.headers.get('Authorization')=='Basic '+base64.b64encode(f'{USER}:{PASSWORD}'.encode()).decode()
  if path.startswith('/plex'):return self.headers.get('X-Plex-Token')==TOKEN
  if path.startswith('/jellyfin'):return f'Token="{TOKEN}"' in self.headers.get('Authorization','')
  if path.startswith('/emby'):return self.headers.get('X-Emby-Token')==TOKEN
  return True
 def media(self):
  start,end=0,len(DATA)-1
  if self.headers.get('Range'):
   r=self.headers['Range'].removeprefix('bytes=').split('-');start=int(r[0]);end=min(int(r[1]) if r[1] else end,end)
  chunk=DATA[start:end+1];code=206 if self.headers.get('Range') else 200
  self.send_response(code);self.send_header('Content-Length',len(chunk));self.send_header('Content-Type','video/x-matroska');self.send_header('Accept-Ranges','bytes')
  if code==206:self.send_header('Content-Range',f'bytes {start}-{end}/{len(DATA)}')
  self.end_headers()
  if self.command!='HEAD':self.wfile.write(chunk)
 def do_HEAD(self):self.do_GET()
 def do_GET(self):
  p=urllib.parse.urlsplit(self.path).path
  if not self.authorized(p):self.send('',code=401);return
  if p.endswith('.mkv') or '/Download' in p:return self.media()
  if p=='/plex/library/sections':return self.send('<MediaContainer size="1"><Directory key="1" type="show"/></MediaContainer>','text/xml')
  if p=='/plex/library/sections/1/all':return self.send('<MediaContainer size="1" totalSize="1"><Video ratingKey="ep1" title="Pilot" grandparentTitle="Fixture" parentIndex="1" index="1"><Media><Part key="/library/parts/ep1/file.mkv" file="Fixture.S01E01.mkv"/></Media></Video></MediaContainer>','text/xml')
  if p.endswith('/Items'):return self.send(json.dumps({'Items':[{'Id':'ep1','Name':'Pilot','SeriesName':'Fixture','ParentIndexNumber':1,'IndexNumber':1,'MediaSources':[{'Container':'mkv'}]}],'TotalRecordCount':1}))
  if p=='/dlna/device.xml':return self.send('<root><device><serviceList><service><serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType><controlURL>/dlna/control</controlURL></service></serviceList></device></root>','text/xml')
  return self.send('',code=404)
 def do_PROPFIND(self):
  p=urllib.parse.urlsplit(self.path).path
  if not self.authorized(p):self.send('',code=401);return
  paths=[(p,True)]
  if p.rstrip('/')=='/dav':paths.append(('/dav/Fixture.S01E01.mkv',False))
  body='<d:multistatus xmlns:d="DAV:">'
  for path,directory in paths:
   body+=f'<d:response><d:href>{path}</d:href><d:propstat><d:prop><d:resourcetype>{"<d:collection/>" if directory else ""}</d:resourcetype><d:getcontentlength>{0 if directory else len(DATA)}</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>'
  self.send(body+'</d:multistatus>','text/xml',207)
 def do_POST(self):
  p=urllib.parse.urlsplit(self.path).path;body=self.rfile.read(int(self.headers.get('Content-Length',0)))
  if p.endswith('/Users/AuthenticateByName'):
   auth=json.loads(body)
   return self.send(json.dumps({'AccessToken':TOKEN,'User':{'Id':'user1'}}) if auth=={'Username':USER,'Pw':PASSWORD} else '{}')
  if p=='/dlna/control':
   didl=f'<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"><item id="ep1"><dc:title>Fixture.S01E01</dc:title><upnp:class>object.item.videoItem</upnp:class><res protocolInfo="http-get:*:video/x-matroska:*">http://127.0.0.1:{self.server.server_port}/media.mkv</res></item></DIDL-Lite>'
   return self.send(f'<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><BrowseResponse><Result>{html.escape(didl)}</Result><NumberReturned>1</NumberReturned><TotalMatches>1</TotalMatches></BrowseResponse></s:Body></s:Envelope>','text/xml')
  self.send('',code=404)
http=ThreadingHTTPServer(('127.0.0.1',0),HTTP);threading.Thread(target=http.serve_forever,daemon=True).start()
auth=DummyAuthorizer();auth.add_user(USER,PASSWORD,str(ROOT),perm='elr')
FTPHandler.authorizer=auth;ftp=FTPServer(('127.0.0.1',0),FTPHandler);threading.Thread(target=ftp.serve_forever,daemon=True).start()
key=paramiko.RSAKey.generate(2048)
class SSH(paramiko.ServerInterface):
 def check_auth_password(self,u,p):return paramiko.AUTH_SUCCESSFUL if (u,p)==(USER,PASSWORD) else paramiko.AUTH_FAILED
 def get_allowed_auths(self,u):return 'password'
 def check_channel_request(self,kind,chanid):return paramiko.OPEN_SUCCEEDED if kind=='session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
class SFTP(paramiko.SFTPServerInterface):
 def local(self,p):return ROOT / p.lstrip('/')
 def list_folder(self,p):
  result=[]
  for f in self.local(p).iterdir():
   a=paramiko.SFTPAttributes.from_stat(f.stat());a.filename=f.name;result.append(a)
  return result
 def stat(self,p):
  try:return paramiko.SFTPAttributes.from_stat(self.local(p).stat())
  except OSError:return paramiko.SFTP_NO_SUCH_FILE
 lstat=stat
 def open(self,p,flags,attr):
  try:
   handle=paramiko.SFTPHandle(flags);handle.readfile=open(self.local(p),'rb');return handle
  except OSError:return paramiko.SFTP_NO_SUCH_FILE
sock=socket.socket();sock.bind(('127.0.0.1',0));sock.listen()
def sftp_loop():
 while True:
  client,_=sock.accept()
  def serve(c):
   t=paramiko.Transport(c);t.add_server_key(key);t.set_subsystem_handler('sftp',paramiko.SFTPServer,SFTP);t.start_server(server=SSH())
   while t.is_active():time.sleep(.1)
  threading.Thread(target=serve,args=(client,),daemon=True).start()
threading.Thread(target=sftp_loop,daemon=True).start()
known=ROOT/'known_hosts';known.write_text(f'[127.0.0.1]:{sock.getsockname()[1]} {key.get_name()} {key.get_base64()}\n')
(ROOT/'manifest.json').write_text(json.dumps({'http':http.server_port,'ftp':ftp.socket.getsockname()[1],'sftp':sock.getsockname()[1],'knownHosts':str(known),'username':USER,'password':PASSWORD,'token':TOKEN,'file':str(ROOT/'Fixture.S01E01.mkv')}))
print('Fixture manifest: '+str(ROOT/'manifest.json'),flush=True)
while True:time.sleep(1)
