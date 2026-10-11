// Local forward proxy on 127.0.0.1:18080 that adds an upstream proxy login
// (CONNECT only). Chrome hangs when Playwright supplies proxy auth itself.
// Reads the login from a file each connection (line 1 user, line 2 password),
// so rotating the IP is just rewriting the file.
//   node tests/authproxy.mjs <cred-file> [upstream-host] [upstream-port]
import net from 'net';
import fs from 'fs';

const [credFile, host = 'geo.iproyal.com', port = '12321'] = process.argv.slice(2);
net.createServer((c) => {
  const [u, p] = fs.readFileSync(credFile, 'utf8').trim().split('\n');
  const auth = Buffer.from(`${u}:${p}`).toString('base64');
  c.once('data', (buf) => {
    const m = buf.toString('latin1').match(/^CONNECT (\S+) HTTP/);
    if (!m) { c.end('HTTP/1.1 405 Method Not Allowed\r\n\r\n'); return; }
    const up = net.connect(Number(port), host, () => {
      up.write(`CONNECT ${m[1]} HTTP/1.1\r\nHost: ${m[1]}\r\nProxy-Authorization: Basic ${auth}\r\n\r\n`);
      up.once('data', (r) => { c.write(r); up.pipe(c); c.pipe(up); });
    });
    up.on('error', () => c.destroy());
    c.on('error', () => up.destroy());
  });
}).listen(18080, '127.0.0.1');
