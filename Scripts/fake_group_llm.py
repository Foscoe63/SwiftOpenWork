import json, sys, re
from http.server import BaseHTTPRequestHandler, HTTPServer
LOG = sys.argv[2]
class H(BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_GET(self):
        self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers()
        self.wfile.write(b'{"data":[{"id":"fake"}]}')
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        msgs = body.get('messages', [])
        sysmsg = next((m['content'] for m in msgs if m['role']=='system'), '')
        who = re.search(r'You are ([A-Za-z ]+?)\.', sysmsg)
        who = who.group(1) if who else '?'
        def txt(m):
            c = m.get('content')
            return c if isinstance(c,str) else ' '.join(p.get('text','') for p in (c or []))
        seen = [(m['role'], txt(m)[:600]) for m in msgs if m['role']!='system']
        rec = {'speaker': who, 'has_tools': bool(body.get('tools')), 'seen': seen, 'system': sysmsg}
        open(LOG,'a').write(json.dumps(rec)+'\n')
        if who == 'Coder':
            reply = "Plan drafted. @Reviewer please check the API shape."
        else:
            others = [t for r,t in seen if t.startswith('[')]
            reply = f"{who} here. I can see {len(others)} tagged message(s) from others: " + ' | '.join(others)
        self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.end_headers()
        ch = lambda d, fin=None: 'data: '+json.dumps({'id':'x','object':'chat.completion.chunk','choices':[{'index':0,'delta':d,'finish_reason':fin}]})+'\n\n'
        self.wfile.write(ch({'role':'assistant','content':reply}).encode())
        self.wfile.write(ch({}, 'stop').encode())
        self.wfile.write(b'data: {"id":"x","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}\n\ndata: [DONE]\n\n')
HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
