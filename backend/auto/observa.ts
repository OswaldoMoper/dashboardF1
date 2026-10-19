// El lector del observador: un Chromium sin ventana que obedece órdenes, una por línea
// de la entrada estándar, y contesta cada una con una línea JSON en la salida estándar.
// No decide nada: cuándo leer, capturar, cerrar o abrir lo manda `dashboardF1-auto`.
//
//   abre <url>      cierra la página que hubiera y abre esa
//   lee             el texto de la banda, Live Timing y Lap Comparison, tal como se ve
//   captura <ruta>  un PNG de lo que se ve
//   cierra          cierra la página
//
// Una orden que falla contesta `"ok": false` con su error y el lector sigue. Al cerrarse
// la entrada, cierra el navegador y sale.
import { chromium, type Browser, type BrowserContext, type Page } from 'playwright-core';

// Las únicas globales de Node que usa; se declaran aquí para que la comprobación de
// tipos no necesite el paquete de tipos de Node.
declare const process: {
  stdin: {
    setEncoding(encoding: 'utf8'): void;
    on(event: 'data', listener: (chunk: string) => void): void;
    on(event: 'end', listener: () => void): void;
  };
  stdout: { write(text: string): boolean };
  exitCode: number | undefined;
};

// El tamaño de la ventana de las pruebas de navegador (`e2e/playwright.config.ts`).
const VIEWPORT = { width: 1912, height: 914 };

// Lo que espera a que una página cargue o a que se haga una captura.
const TIMEOUT_MS = 15000;

type Answer = { orden: string; ok: boolean; ms: number; error?: string; [k: string]: unknown };

let browser: Browser | undefined;
let context: BrowserContext | undefined;
let page: Page | undefined;
// Errores de consola y peticiones fallidas desde la última lectura.
let problems: string[] = [];

function reply(answer: Answer): void {
  process.stdout.write(JSON.stringify(answer) + '\n');
}

async function close(): Promise<void> {
  const old = context;
  context = undefined;
  page = undefined;
  if (old) await old.close();
}

async function open(url: string): Promise<void> {
  await close();
  browser ??= await chromium.launch({ headless: true });
  context = await browser.newContext({ viewport: VIEWPORT });
  const p = await context.newPage();
  problems = [];
  p.on('console', (m) => {
    if (m.type() === 'error') problems.push(`consola: ${m.text()}`);
  });
  p.on('pageerror', (e) => problems.push(`excepción: ${e.message}`));
  p.on('requestfailed', (r) =>
    problems.push(`falló ${r.method()} ${r.url()}: ${r.failure()?.errorText ?? '?'}`),
  );
  p.on('response', (r) => {
    if (r.status() >= 400) problems.push(`${r.status()} ${r.request().method()} ${r.url()}`);
  });
  page = p;
  await p.goto(url, { waitUntil: 'load', timeout: TIMEOUT_MS });
}

// Lo que se ve de la capa del layout a la vista. Corre dentro de la página.
function readPage() {
  const shown = (e: Element) => e.checkVisibility({ visibilityProperty: true });
  // El texto a la vista de un elemento, con cada desplegable reducido a su opción elegida.
  const seen = (root: Element | null): string => {
    if (!root || !shown(root)) return '';
    const parts: string[] = [];
    const walk = (n: Node): void => {
      if (n.nodeType === Node.TEXT_NODE) {
        parts.push(n.textContent ?? '');
      } else if (n instanceof HTMLSelectElement) {
        if (shown(n)) parts.push(` ${n.selectedOptions[0]?.text ?? ''} `);
      } else if (n instanceof Element && shown(n)) {
        parts.push(' ');
        n.childNodes.forEach(walk);
        parts.push(' ');
      }
    };
    walk(root);
    return parts.join('').replace(/\s+/g, ' ').trim();
  };
  const all = (root: Element | null, selector: string): Element[] =>
    root ? Array.from(root.querySelectorAll(selector)).filter(shown) : [];
  const texts = (root: Element | null, selector: string): string[] =>
    all(root, selector).map(seen).filter((t) => t !== '');

  const layer = document.querySelector('.canvas__layer:not(.canvas__layer--hidden)');
  const band = document.querySelector('.session-band');
  const timing = layer?.querySelector('.widget--live-timing') ?? null;
  const comparison = layer?.querySelector('.widget--comparison') ?? null;
  const badge = comparison?.querySelector('.comparison__live') ?? null;
  const curve = comparison?.querySelector('.comparison__canvas polyline') ?? null;
  const look = band?.querySelector('.session-band__look') ?? null;

  return {
    url: location.href,
    banda: {
      texto: seen(band).replace(seen(look), '').trim(),
      estado: seen(band?.querySelector('.session-band__state') ?? null),
      siguiente: seen(band?.querySelector('.session-band__next') ?? null),
      // El aviso solo se ve al pulsar el estado; se guarda aunque esté cerrado.
      aviso: band?.querySelector('.session-band__note')?.textContent?.trim() ?? '',
      banderas: all(band, '.session-band__flag').map((f) => f.getAttribute('title') ?? ''),
    },
    liveTiming: {
      texto: seen(timing),
      cabecera: seen(timing?.querySelector('.widget__head') ?? null),
      columnas: texts(timing, 'table.live-timing thead th'),
      filas: all(timing, 'table.live-timing tbody tr').map((tr) =>
        Array.from(tr.querySelectorAll('td')).map(seen),
      ),
      avisos: texts(timing, '.status, .live-timing__cutoff'),
    },
    lapComparison: {
      texto: seen(comparison),
      cabecera: seen(comparison?.querySelector('.widget__head') ?? null),
      live: badge !== null && shown(badge),
      vuelta: seen(comparison?.querySelector('.comparison__rule-btn--on') ?? null),
      avisos: texts(comparison, '.status, .comparison__note'),
      fronteras: texts(comparison, '.comparison__frontier'),
      puntosCurva:
        curve === null ? 0 : (curve.getAttribute('points') ?? '').trim().split(/\s+/).filter(Boolean).length,
    },
  };
}

async function run(line: string): Promise<void> {
  const [orden = '', ...rest] = line.trim().split(' ');
  const arg = rest.join(' ');
  const started = Date.now();
  const done = (extra: Record<string, unknown> = {}) =>
    reply({ orden, ok: true, ms: Date.now() - started, ...extra });
  try {
    if (orden === 'abre' && arg) {
      await open(arg);
      done();
    } else if (orden === 'lee' && page) {
      const lectura = await page.evaluate(readPage);
      const seenProblems = problems;
      problems = [];
      done({ lectura: { ...lectura, problemas: seenProblems } });
    } else if (orden === 'captura' && arg && page) {
      await page.screenshot({ path: arg, type: 'png', timeout: TIMEOUT_MS });
      done({ ruta: arg });
    } else if (orden === 'cierra') {
      await close();
      done();
    } else {
      const why = ['lee', 'captura'].includes(orden) && !page ? 'no hay página abierta' : 'orden desconocida';
      reply({ orden, ok: false, ms: Date.now() - started, error: why });
    }
  } catch (e) {
    reply({ orden, ok: false, ms: Date.now() - started, error: e instanceof Error ? e.message : String(e) });
  }
}

// Las órdenes se atienden una a una, en el orden en que llegan.
let queue: Promise<void> = Promise.resolve();
let pending = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  pending += chunk;
  const lines = pending.split('\n');
  pending = lines.pop() ?? '';
  for (const line of lines) {
    if (line.trim()) queue = queue.then(() => run(line));
  }
});
process.stdin.on('end', () => {
  queue = queue
    .then(() => (pending.trim() ? run(pending) : undefined))
    .then(close)
    .then(() => browser?.close())
    .catch(() => {
      process.exitCode = 1;
    });
});
