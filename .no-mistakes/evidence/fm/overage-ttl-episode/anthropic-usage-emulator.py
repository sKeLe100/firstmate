import json,ssl,socket,socketserver,sys,time,os,datetime
L=sys.argv[1]
def iso(s): return (datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(seconds=s)).strftime('%Y-%m-%dT%H:%M:%SZ')
def usage(mode):
    s,w,m,x=10,20,10,False
    if mode=='session-exhausted': s=100
    if mode=='weekly-exhausted': w=100
    if mode=='opus-exhausted': m=100
    if mode=='extra-usage': w=100; x=True
    d={"limits":[{"group":"session","percent":s,"resets_at":iso(9000)},
                 {"group":"weekly","percent":w,"resets_at":iso(300000)},
                 {"percent":m,"resets_at":iso(300000),"scope":{"model":{"display_name":"Opus"}}}]}
    if x: d["extra_usage"]={"is_enabled":True,"used_credits":500,"monthly_limit":10000,"utilization":5,"currency":"USD","decimal_places":2}
    return d
class H(socketserver.BaseRequestHandler):
    def handle(self):
        c=self.request; b=b''
        while b'\r\n\r\n' not in b:
            d=c.recv(4096)
            if not d: return
            b+=d
        line=b.split(b'\r\n')[0].decode()
        if not line.startswith('CONNECT api.anthropic.com:443'):
            c.sendall(b'HTTP/1.1 403 no\r\n\r\n'); return
        c.sendall(b'HTTP/1.1 200 OK\r\n\r\n')
        x=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); x.load_cert_chain(L+'/srv/s.pem',L+'/srv/s.key')
        t=x.wrap_socket(c,server_side=True)
        r=b''
        while b'\r\n\r\n' not in r:
            d=t.recv(4096)
            if not d: return
            r+=d
        path=r.split()[1].decode()
        tok=[l for l in r.decode().split('\r\n') if l.lower().startswith('authorization')][0].split()[-1]
        try: mode=open(L+'/mode/'+tok).read().strip()
        except OSError: mode='healthy'
        with open(L+'/srv/requests.log','a') as f: f.write(f'{time.strftime("%T")} {path} token={tok} mode={mode}\n')
        code,body=200,None
        if path.startswith('/api/oauth/profile'): body=json.dumps({"account":{"uuid":tok,"email":tok+"@example.invalid"}})
        elif mode=='http500': code,body=500,'{"error":"boom"}'
        elif mode=='badjson': body='<html>nope'
        elif mode=='hang': time.sleep(30); return
        else: body=json.dumps(usage(mode))
        t.sendall(f'HTTP/1.1 {code} X\r\nContent-Type: application/json\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n{body}'.encode())
class S(socketserver.ThreadingMixIn,socketserver.TCPServer): daemon_threads=True
s=S(('127.0.0.1',0),H); open(L+'/srv/port','w').write(str(s.server_address[1])); s.serve_forever()
