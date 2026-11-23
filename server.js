'use strict';

const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const HOST = '127.0.0.1';
const BASE_PORT = 8080;
const MAX_PORT = 8090;
const ROOT_DIR = path.resolve(__dirname);
const LOG_FILE = path.join(ROOT_DIR, 'vr-debug.log');

const MIME_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.mjs': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.svg': 'image/svg+xml; charset=utf-8',
  '.ico': 'image/x-icon',
  '.wasm': 'application/wasm',
  '.glb': 'model/gltf-binary',
  '.gltf': 'model/gltf+json',
  '.mp3': 'audio/mpeg',
  '.wav': 'audio/wav'
};

let psvrUsbInFlight = false;

/**
 * Invoke psvr-usb.ps1 safely to switch PSVR WinUSB modes without Chrome WebUSB restrictions.
 * @param {'vr-mode'|'cinematic-mode'|'status'} action
 * @param {(result: object) => void} callback
 */
function runPsvrUsbHelper(action, callback) {
  if (psvrUsbInFlight) {
    callback({
      ok: false,
      code: 'IN_FLIGHT',
      error: 'Ya hay una operación USB del PSVR en curso. Espera un segundo y reintenta.'
    });
    return;
  }

  psvrUsbInFlight = true;
  const scriptPath = path.join(ROOT_DIR, 'psvr-usb.ps1');
  const args = [
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    scriptPath,
    action
  ];

  let finished = false;
  const finish = (result) => {
    if (finished) return;
    finished = true;
    psvrUsbInFlight = false;
    const summary = `[PSVR-USB] action=${action} ok=${Boolean(result.ok)} code=${result.code || '-'} pipe=${result.pipe || '-'} err=${result.error || '-'}`;
    console.log(summary);
    fs.appendFile(LOG_FILE, `[${new Date().toISOString()}] ${summary}\n`, () => {});
    callback(result);
  };

  let child;
  try {
    child = spawn('powershell.exe', args, { windowsHide: true });
  } catch (err) {
    finish({
      ok: false,
      code: 'SPAWN_ERR',
      error: `No se pudo iniciar el puente PowerShell WinUSB: ${err.message}`
    });
    return;
  }

  let stdout = '';
  let stderr = '';
  child.stdout.on('data', (chunk) => {
    stdout += chunk.toString('utf8');
  });
  child.stderr.on('data', (chunk) => {
    stderr += chunk.toString('utf8');
  });

  const timer = setTimeout(() => {
    try { child.kill(); } catch {}
    finish({
      ok: false,
      code: 'TIMEOUT',
      error: 'Tiempo de espera agotado al comunicar con el USB del PSVR.'
    });
  }, 8000);

  child.on('error', (err) => {
    clearTimeout(timer);
    finish({
      ok: false,
      code: 'CHILD_ERR',
      error: `Error al ejecutar psvr-usb.ps1: ${err.message}`
    });
  });

  child.on('close', () => {
    clearTimeout(timer);
    const lines = stdout
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean);
    for (let i = lines.length - 1; i >= 0; i--) {
      try {
        const parsed = JSON.parse(lines[i]);
        if (parsed && typeof parsed === 'object') {
          finish(parsed);
          return;
        }
      } catch {
        // Seguir buscando la línea JSON
      }
    }
    const errText = stderr.trim().replace(/[\r\n]+/g, ' ').slice(0, 260);
    finish({
      ok: false,
      code: 'PARSE_ERR',
      error: errText || 'Respuesta inesperada del puente WinUSB del PSVR.'
    });
  });
}

function sendJson(res, statusCode, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(statusCode, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body, 'utf8'),
    'Cache-Control': 'no-store'
  });
  res.end(body);
}

/**
 * Resolve a request URL path safely within ROOT_DIR, guarding against traversal.
 * @param {string} rawUrl
 * @returns {{ status: number, filePath?: string }}
 */
function resolveSafePath(rawUrl) {
  let pathname;
  try {
    pathname = decodeURIComponent((rawUrl || '/').split('?')[0].split('#')[0]);
  } catch {
    return { status: 400 };
  }

  const normalizedRel = pathname === '/' ? 'index.html' : pathname.replace(/^\/+/, '');
  if (!normalizedRel) {
    return { status: 200, filePath: path.join(ROOT_DIR, 'index.html') };
  }

  const segments = normalizedRel.split(/[\\/]/);
  if (segments.includes('..')) {
    return { status: 403 };
  }

  const resolved = path.resolve(ROOT_DIR, normalizedRel);
  if (resolved !== ROOT_DIR && !resolved.startsWith(ROOT_DIR + path.sep)) {
    return { status: 403 };
  }

  return { status: 200, filePath: resolved };
}

/**
 * Send a plain-text HTTP error response.
 * @param {http.ServerResponse} res
 * @param {number} statusCode
 * @param {string} message
 */
function sendError(res, statusCode, message) {
  res.writeHead(statusCode, {
    'Content-Type': 'text/plain; charset=utf-8',
    'Cache-Control': 'no-store'
  });
  res.end(message);
}

/**
 * Handle incoming HTTP requests for static project files.
 * @param {http.IncomingMessage} req
 * @param {http.ServerResponse} res
 */
function handleRequest(req, res) {
  let parsedUrl;
  try {
    parsedUrl = new URL(req.url || '/', 'http://localhost');
  } catch {
    sendError(res, 400, '400 Bad Request');
    return;
  }

  if (parsedUrl.pathname === '/log') {
    if (req.method !== 'GET' && req.method !== 'POST') {
      sendError(res, 405, '405 Method Not Allowed');
      return;
    }
    const rawMsg = parsedUrl.searchParams.get('m') || '';
    const cleanMsg = rawMsg.replace(/[\r\n]+/g, ' ').trim().slice(0, 400);
    const line = `[${new Date().toISOString()}] ${cleanMsg}\n`;
    console.log('[VR-LOG]', cleanMsg);
    fs.appendFile(LOG_FILE, line, () => {});
    if (req.method === 'POST') {
      req.resume();
    }
    res.writeHead(204, { 'Cache-Control': 'no-store' });
    res.end();
    return;
  }

  if (
    parsedUrl.pathname === '/psvr/vr-mode' ||
    parsedUrl.pathname === '/psvr/cinematic-mode' ||
    parsedUrl.pathname === '/psvr/status'
  ) {
    if (req.method !== 'GET' && req.method !== 'POST') {
      sendError(res, 405, '405 Method Not Allowed');
      return;
    }
    if (req.method === 'POST') {
      req.resume();
    }
    const action =
      parsedUrl.pathname === '/psvr/vr-mode'
        ? 'vr-mode'
        : parsedUrl.pathname === '/psvr/cinematic-mode'
          ? 'cinematic-mode'
          : 'status';
    runPsvrUsbHelper(action, (result) => {
      const code = result && result.code === 'IN_FLIGHT' ? 409 : 200;
      sendJson(res, code, result);
    });
    return;
  }

  if (req.method !== 'GET' && req.method !== 'HEAD') {
    sendError(res, 405, '405 Method Not Allowed');
    return;
  }

  const lookup = resolveSafePath(req.url);
  if (lookup.status !== 200 || !lookup.filePath) {
    sendError(res, lookup.status, `${lookup.status} Forbidden`);
    return;
  }

  fs.stat(lookup.filePath, (statErr, stats) => {
    if (statErr || !stats.isFile()) {
      sendError(res, 404, '404 Not Found');
      return;
    }

    const ext = path.extname(lookup.filePath).toLowerCase();
    const contentType = MIME_TYPES[ext] || 'application/octet-stream';

    res.writeHead(200, {
      'Content-Type': contentType,
      'Content-Length': stats.size,
      'Cache-Control': 'no-store'
    });

    if (req.method === 'HEAD') {
      res.end();
      return;
    }

    const stream = fs.createReadStream(lookup.filePath);
    stream.on('error', () => {
      if (!res.headersSent) {
        sendError(res, 500, '500 Internal Server Error');
      } else {
        res.destroy();
      }
    });
    stream.pipe(res);
  });
}

/**
 * Open the local WebXR URL in Chrome or Edge (fallback to default shell handler).
 * @param {string} url
 * @param {boolean} preferEdge
 */
function openBrowser(url, preferEdge = false) {
  const chromePaths = [
    'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
    'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe'
  ];
  const edgePaths = [
    'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
    'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe'
  ];
  const browserCandidates = preferEdge ? [...edgePaths, ...chromePaths] : [...chromePaths, ...edgePaths];

  const executable = browserCandidates.find((candidate) => fs.existsSync(candidate));
  try {
    if (executable) {
      const isEdge = executable.toLowerCase().includes('msedge');
      const vrProfileDir = path.join(os.tmpdir(), isEdge ? 'eppei-webxr-edge-profile' : 'eppei-webxr-profile');
      const args = [
        `--app=${url}?vr=1`,
        `--user-data-dir=${vrProfileDir}`,
        '--no-first-run',
        '--no-default-browser-check',
        '--window-size=1280,820'
      ];
      const child = spawn(executable, args, {
        detached: true,
        stdio: 'ignore'
      });
      child.unref();
      return;
    }

    const child = spawn('cmd.exe', ['/c', 'start', '""', url], {
      detached: true,
      stdio: 'ignore',
      windowsHide: true
    });
    child.unref();
  } catch (err) {
    console.warn(`No se pudo abrir el navegador automaticamente: ${err.message}`);
    console.warn(`Abre manualmente en Chrome o Edge: ${url}`);
  }
}

/**
 * Print startup instructions in Spanish once the HTTP server is listening.
 * @param {number} port
 */
function printBanner(port) {
  const url = `http://localhost:${port}/`;
  console.log('===============================================================');
  console.log('  Es perfecto porque es imperfecto — Servidor PSVR Directo 360');
  console.log('===============================================================');
  console.log(`  URL activa : ${url}`);
  console.log(`  Perfil VR  : ?vr=1 optimizado para AMD Vega 8 / PSVR Directo`);
  console.log(`  Carpeta    : ${ROOT_DIR}`);
  console.log('');
  console.log('  Pasos para inmersion total 360 en PSVR (sin SteamVR):');
  console.log('   1. Cierra SteamVR e iVRy completamente (libera USB y HDMI).');
  console.log('   2. Deja el PSVR como Pantalla 2 ampliada (Win + P -> Ampliar).');
  console.log('   3. En la ventana que se abre en el PC, pulsa en orden:');
  console.log('      1) Activar modo VR del PSVR (USB)');
  console.log('      2) Conectar giroscopio PSVR (HID)');
  console.log('      3) PROYECTAR EN PSVR 360 (PANTALLA COMPLETA)');
  console.log('   4. Si abre en el portatil en vez del visor: Win + Shift + -> o F.');
  console.log('');
  console.log('  Para detener este servidor, pulsa Ctrl+C en esta ventana.');
  console.log('===============================================================');
}

/**
 * Start the HTTP server on BASE_PORT, incrementing up to MAX_PORT on EADDRINUSE.
 * @param {number} port
 * @param {boolean} shouldOpen
 */
function startServer(port, shouldOpen, preferEdge) {
  const server = http.createServer(handleRequest);

  server.on('error', (err) => {
    if (err.code === 'EADDRINUSE' && port < MAX_PORT) {
      startServer(port + 1, shouldOpen, preferEdge);
      return;
    }
    console.error(`Error al iniciar el servidor en ${HOST}:${port}: ${err.message}`);
    process.exit(1);
  });

  server.listen(port, HOST, () => {
    const url = `http://localhost:${port}/`;
    try {
      fs.writeFileSync(
        LOG_FILE,
        `=== WebXR Session Log started ${new Date().toISOString()} on ${url} (preferEdge=${preferEdge}) ===\n`,
        'utf8'
      );
    } catch {}
    printBanner(port);
    if (shouldOpen) {
      openBrowser(url, preferEdge);
    }
  });

  const shutdown = () => {
    console.log('\nDeteniendo servidor WebXR...');
    server.close(() => process.exit(0));
  };

  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

const shouldOpen = process.argv.includes('--open');
const preferEdge = process.argv.includes('--edge');
startServer(BASE_PORT, shouldOpen, preferEdge);
