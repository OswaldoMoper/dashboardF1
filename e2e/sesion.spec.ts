import { expect, test, type Page } from '@playwright/test';
import { openDashboard } from './serve';
import feedP3 from './recordings/live-feed-p3.json';

// Las peticiones a `/api/*` que salen de la página abierta en `from`, con su query. La
// dirección de quien pide separa estas de las que aún lance la carga de `openDashboard`.
function apiRequests(page: Page, from: string): string[] {
  const seen: string[] = [];
  page.on('request', (request) => {
    const { pathname, search } = new URL(request.url());
    const asker = new URL(request.frame().url());
    if (pathname.startsWith('/api/') && asker.pathname + asker.search === from) seen.push(pathname + search);
  });
  return seen;
}

// Lo que el HAR no conoce se aborta, así que las peticiones con sesión se contestan aquí:
// la tabla (la de la P3 si no se da otra) como venida de FastF1, y listas vacías en lo demás.
async function answerSession(page: Page, table: object = feedP3): Promise<void> {
  await page.route(/\/api\/[a-z-]+\?(.*&)?session=/, (route) => {
    const { pathname } = new URL(route.request().url());
    if (pathname !== '/api/live') return route.fulfill({ json: [] });
    return route.fulfill({
      contentType: 'application/json;charset=utf-8',
      headers: { 'X-Data-Source': 'fastf1', 'X-Data-Origin': 'live', 'X-Data-Fetched-At': new Date().toISOString() },
      body: JSON.stringify(table),
    });
  });
}

test('con ?sesion= en la dirección, las cuatro peticiones de datos llevan esa sesión', async ({ page }) => {
  await openDashboard(page);
  await answerSession(page);
  const seen = apiRequests(page, '/?retraso=0&sesion=2026-20-r');
  await page.goto('/?retraso=0&sesion=2026-20-r');
  for (const path of ['/api/live', '/api/historical', '/api/drivers', '/api/comparison']) {
    await expect.poll(() => seen.filter((r) => r.startsWith(path + '?'))).toContain(`${path}?session=2026-20-R`);
  }
  // El directo se sigue pidiendo por detrás, sin sesión; lo demás, solo con ella.
  await expect.poll(() => seen).toContain('/api/live');
  expect(seen.filter((r) => /^\/api\/(historical|drivers|comparison)$/.test(r))).toEqual([]);
});

test('con una sesión elegida el Diferido no se le aplica: se enseña al momento y el campo se atenúa', async ({ page }) => {
  await openDashboard(page);
  await answerSession(page);
  await page.goto('/?sesion=2026-20-R');
  await expect(page.locator('.delay-field__input')).toHaveValue('0:41');
  await expect(page.locator('.delay-field')).toHaveClass(/delay-field--idle/);
  await expect(page.locator('.delay-field__note')).toBeVisible();
  await expect(page.locator('.canvas__layer').nth(0).locator('.widget--live-timing tbody tr')).toHaveCount(22, { timeout: 8000 });
});

test('sin ?sesion=, ninguna petición de datos lleva sesión', async ({ page }) => {
  await openDashboard(page);
  const seen = apiRequests(page, '/?retraso=0');
  await page.goto('/?retraso=0');
  await expect.poll(() => seen).toContain('/api/live');
  await expect.poll(() => seen).toContain('/api/historical');
  expect(seen.filter((r) => r.includes('session='))).toEqual([]);
  await expect(page.locator('.delay-field')).not.toHaveClass(/delay-field--idle/);
  await expect(page.locator('.delay-field__note')).toBeHidden();
});

test('con una sesión elegida, Tyre Strategy pinta los stints aunque la tabla no venga del feed', async ({ page }) => {
  await openDashboard(page);
  await answerSession(page);
  await page.goto('/?retraso=0&sesion=2026-20-R');
  await page.getByRole('button', { name: 'Strategy', exact: true }).click();
  const card = page.locator('.canvas__layer').nth(2).locator('.widget--tyre-strategy');
  await expect(card.locator('.tyre-strategy__row')).toHaveCount(22);
  await expect(card.locator('.tyre-strategy__bar')).toHaveCount(40);
  await expect(card.locator('.tyre-strategy__notice')).toHaveCount(0);
});

test('una sesión elegida sin filas ni clasificación enseña sus avisos en lugar de tablas vacías', async ({ page }) => {
  await openDashboard(page);
  await answerSession(page, { ...feedP3, liveRows: [], liveStints: [] });
  await page.goto('/?retraso=0&sesion=2026-21-R');
  const overview = page.locator('.canvas__layer').nth(0);
  await expect(overview.locator('.widget--live-timing .status--empty')).toHaveText('Sesión aún sin correr');
  await expect(overview.locator('.widget--live-timing table')).toHaveCount(0);
  await expect(overview.locator('.widget--driver-stats .status--empty')).toHaveText('Sin clasificación todavía');
  await expect(overview.locator('.widget--constructor-stats .status--empty')).toHaveText('Sin clasificación todavía');
  await page.getByRole('button', { name: 'Strategy', exact: true }).click();
  const card = page.locator('.canvas__layer').nth(2).locator('.widget--tyre-strategy');
  await expect(card.locator('.status--empty')).toHaveText('Sesión aún sin correr');
  await expect(card.locator('.tyre-strategy__legend')).toHaveCount(0);
});

// Dos sesiones con su tabla: 2026-20-R con la de la P3 y 2026-21-R sin filas («Sesión aún sin
// correr»); la de 2026-20-R tarda `slow` ms. Lo demás, listas vacías.
async function answerTwo(page: Page, slow = 0): Promise<void> {
  await page.route(/\/api\/[a-z-]+\?(.*&)?session=/, async (route) => {
    const url = new URL(route.request().url());
    if (url.pathname !== '/api/live') return route.fulfill({ json: [] });
    const first = url.searchParams.get('session') === '2026-20-R';
    if (first && slow > 0) await new Promise((done) => setTimeout(done, slow));
    return route.fulfill({
      contentType: 'application/json;charset=utf-8',
      headers: { 'X-Data-Source': 'fastf1', 'X-Data-Origin': 'live', 'X-Data-Fetched-At': new Date().toISOString() },
      body: JSON.stringify(first ? feedP3 : { ...feedP3, liveRows: [], liveStints: [] }),
    });
  });
}

// Como el selector: cambia la dirección sin recargar y avisa a la página.
async function moveTo(page: Page, address: string): Promise<void> {
  await page.evaluate((to) => {
    history.pushState({}, '', to);
    dispatchEvent(new PopStateEvent('popstate'));
  }, address);
}

test('al cambiar de sesión sin recargar, se pide la nueva y «Atrás» vuelve a la anterior', async ({ page }) => {
  await openDashboard(page);
  await answerTwo(page);
  await page.goto('/?retraso=0&sesion=2026-20-R');
  const timing = page.locator('.canvas__layer').nth(0).locator('.widget--live-timing');
  await expect(timing.locator('tbody tr')).toHaveCount(22);
  const seen = apiRequests(page, '/?retraso=0&sesion=2026-21-R');
  await moveTo(page, '/?retraso=0&sesion=2026-21-R');
  await expect(timing.locator('.status--empty')).toHaveText('Sesión aún sin correr');
  for (const path of ['/api/live', '/api/historical', '/api/drivers', '/api/comparison']) {
    await expect.poll(() => seen.filter((r) => r.startsWith(path + '?'))).toContain(`${path}?session=2026-21-R`);
  }
  await page.goBack();
  await expect(timing.locator('tbody tr')).toHaveCount(22);
});

test('la respuesta tardía de la sesión anterior no pisa la nueva', async ({ page }) => {
  await openDashboard(page);
  await answerTwo(page, 2500);
  await page.goto('/?retraso=0&sesion=2026-20-R');
  await moveTo(page, '/?retraso=0&sesion=2026-21-R');
  const timing = page.locator('.canvas__layer').nth(0).locator('.widget--live-timing');
  await expect(timing.locator('.status--empty')).toHaveText('Sesión aún sin correr');
  await page.waitForTimeout(3500);
  await expect(timing.locator('.status--empty')).toHaveText('Sesión aún sin correr');
  await expect(timing.locator('tbody tr')).toHaveCount(0);
});

// La temporada del selector: São Paulo corrida entera y Las Vegas con la Q corrida y la
// carrera por correr, a horas relativas a ahora; con `vegasRace` negativo, la carrera ya
// empezó hace esos segundos.
async function answerSeason(page: Page, vegasRace = 86400): Promise<void> {
  const now = Math.floor(Date.now() / 1000);
  const race = (round: number, name: string, starts: [string, number][]) =>
    ({ raceRound: round, raceName: name, raceSessions: starts.map(([code, t]) => ({ ssnKey: `2026-${round}-${code}`, ssnStart: t })) });
  await page.route((url) => url.pathname === '/api/season', (route) => route.fulfill({
    json: [
      race(20, 'São Paulo Grand Prix', [['Q', now - 90000], ['R', now - 80000]]),
      race(21, 'Las Vegas Grand Prix', [['Q', now - 3600], ['R', now + vegasRace]]),
    ],
  }));
}

test('el título de la banda abre la lista; elegir una sesión la pone en la dirección y la pide', async ({ page }) => {
  await openDashboard(page);
  await answerTwo(page);
  await answerSeason(page);
  await page.goto('/?retraso=0');
  await page.locator('.session-band__pick').click();
  const panel = page.locator('.session-band__panel');
  await expect(panel).toBeVisible();
  await expect(panel.locator('.session-band__race-name')).toHaveText(['R21 Las Vegas Grand Prix', 'R20 São Paulo Grand Prix']);
  await expect(panel.locator('.session-band__race').nth(0).getByRole('button', { name: 'R', exact: true })).toBeDisabled();
  await panel.locator('.session-band__race').nth(1).getByRole('button', { name: 'R', exact: true }).click();
  await expect(page).toHaveURL(/\?retraso=0&sesion=2026-20-R$/);
  await expect(panel).toBeHidden();
  await expect(page.locator('.canvas__layer').nth(0).locator('.widget--live-timing tbody tr')).toHaveCount(22);
});

test('«Ahora» quita la sesión de la dirección, y Escape cierra la lista', async ({ page }) => {
  await openDashboard(page);
  await answerTwo(page);
  await answerSeason(page);
  await page.goto('/?retraso=0&sesion=2026-21-R');
  const panel = page.locator('.session-band__panel');
  await page.locator('.session-band__pick').click();
  await expect(panel.locator('.session-band__code--chosen')).toHaveText('R');
  await page.keyboard.press('Escape');
  await expect(panel).toBeHidden();
  // Las peticiones de la sesión nueva pueden salir antes de que cambie la dirección (mismo
  // frame): se cuentan todas desde aquí, sin mirar desde qué dirección salieron.
  const seen: string[] = [];
  page.on('request', (request) => {
    const { pathname, search } = new URL(request.url());
    if (pathname.startsWith('/api/')) seen.push(pathname + search);
  });
  await page.locator('.session-band__pick').click();
  await panel.getByRole('button', { name: 'Ahora (lo último y el directo)' }).click();
  await expect(page).toHaveURL(/\/\?retraso=0$/);
  // El directo ya se pedía por detrás: al volver se enseña sin pedirlo; lo demás se pide sin sesión.
  for (const path of ['/api/historical', '/api/drivers', '/api/comparison']) {
    await expect.poll(() => seen).toContain(path);
  }
});

// La comparación de ejemplo es la que da el backend a una sesión sin correr: si la tarjeta la
// enseñara, saldrían sus pilotos y su aviso amarillo.
test('una sesión elegida sin filas enseña el aviso en Lap Comparison, no la comparación de ejemplo', async ({ page }) => {
  await openDashboard(page);
  await answerSession(page, { ...feedP3, liveRows: [], liveStints: [] });
  const entry = (car: string, driver: string, lap: string, sectors: number[]) =>
    ({ ceCar: car, ceDriver: driver, ceLap: lap, cePart: null, ceSectors: sectors, ceFrontiers: null, ceTrace: [] });
  await page.route(
    (url) => url.pathname === '/api/comparison',
    (route) => route.fulfill({
      contentType: 'application/json;charset=utf-8',
      headers: { 'X-Data-Origin': 'sample' },
      body: JSON.stringify({
        lcEntries: [entry('16', 'LEC', '1:29.512', [29, 31, 29.512]), entry('1', 'NOR', '1:29.345', [29.048, 30.871, 29.426])],
        lcNotice: '', lcSamples: 0, lcTelemetry: null,
      }),
    }),
  );
  await page.goto('/?retraso=0&sesion=2026-21-R');
  const card = page.locator('.canvas__layer').nth(0).locator('.widget--comparison');
  await expect(card.locator('.status--empty')).toHaveText('Sesión aún sin correr');
  await expect(card.locator('.comparison__body')).toBeHidden();
  await expect(card.locator('.comparison__legend')).toBeHidden();
  await expect(card.getByText('Datos de ejemplo')).toBeHidden();
  await expect(card.locator('h2')).toHaveText('Lap Comparison');
});

// El directo sin sesión, rodando: la carrera de Las Vegas en la vuelta 30 de 50.
async function answerRollingLive(page: Page): Promise<void> {
  const live = {
    ...feedP3,
    liveNext: { tag: 'NextSilent' },
    liveSession: {
      ...feedP3.liveSession,
      siType: 'Race', siName: 'Race',
      siState: { srBasis: 'Heard', srState: 'Started' },
      siLaps: { lpCurrent: 30, lpTotal: 50 },
    },
  };
  await page.route(
    (url) => url.pathname === '/api/live' && !url.searchParams.has('session'),
    (route) => route.fulfill({
      contentType: 'application/json;charset=utf-8',
      headers: { 'X-Data-Source': 'feed', 'X-Data-Origin': 'live', 'X-Data-Fetched-At': new Date().toISOString() },
      body: JSON.stringify(live),
    }),
  );
}

test('con otra sesión elegida y el directo rodando, el aviso ocupa la cuenta atrás y «Volver» vuelve al directo', async ({ page }) => {
  await openDashboard(page);
  await answerSession(page);
  await answerRollingLive(page);
  await page.goto('/?retraso=0&sesion=2026-20-R');
  const aside = page.locator('.session-band__live');
  await expect(aside.locator('.session-band__live-text')).toHaveText('● EN DIRECTO: Las Vegas Grand Prix · Race · vuelta 30/50');
  await expect(page.locator('.session-band__next')).toBeHidden();
  await aside.getByRole('button', { name: 'Volver' }).click();
  await expect(page).toHaveURL(/\/\?retraso=0$/);
  await expect(aside).toBeHidden();
  await expect(page.locator('.session-band__next')).toHaveText('Vuelta 30/50');
});

test('con otra sesión elegida y el directo ya finalizado, no hay aviso y sigue la cuenta atrás', async ({ page }) => {
  await openDashboard(page);
  await answerSession(page);
  await page.goto('/?retraso=0&sesion=2026-20-R');
  await expect(page.locator('.canvas__layer').nth(0).locator('.widget--live-timing tbody tr')).toHaveCount(22);
  await expect(page.locator('.session-band__next')).toBeVisible();
  await expect(page.locator('.session-band__live')).toBeHidden();
});

test('la sesión que rueda lleva «●» en la lista, y pulsarla es «Ahora»', async ({ page }) => {
  await openDashboard(page);
  await answerSession(page);
  await answerRollingLive(page);
  await answerSeason(page, -1800);
  await page.goto('/?retraso=0&sesion=2026-20-R');
  await expect(page.locator('.session-band__live')).toBeVisible();
  await page.locator('.session-band__pick').click();
  const panel = page.locator('.session-band__panel');
  const vegasRace = panel.locator('.session-band__race').nth(0).locator('.session-band__code').last();
  await expect(vegasRace).toHaveText('● R');
  await expect(panel.locator('.session-band__live-dot')).toHaveCount(1);
  await vegasRace.click();
  await expect(page).toHaveURL(/\/\?retraso=0$/);
  await expect(page.locator('.session-band__live')).toBeHidden();
});

test('si la última sesión empezada no es del tipo del directo, ninguna lleva «●»', async ({ page }) => {
  await openDashboard(page);
  await answerSession(page);
  await answerRollingLive(page);
  await answerSeason(page);
  await page.goto('/?retraso=0&sesion=2026-20-R');
  await expect(page.locator('.session-band__live')).toBeVisible();
  await page.locator('.session-band__pick').click();
  const panel = page.locator('.session-band__panel');
  await expect(panel.locator('.session-band__race-name')).toHaveText(['R21 Las Vegas Grand Prix', 'R20 São Paulo Grand Prix']);
  await expect(panel.locator('.session-band__live-dot')).toHaveCount(0);
});
