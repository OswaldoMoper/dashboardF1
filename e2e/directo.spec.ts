import { expect, test } from '@playwright/test';
import type { Page, Route } from '@playwright/test';
import { openDashboard } from './serve';

// El refresco va cada 10 s desde que se monta la página, que es cuando sale la primera
// petición, así que una segunda que arranca antes de 9,5 s solo puede venir de volver a
// la pestaña. Con la primera aún en vuelo no se pide otra, así que se vuelve a la pestaña
// cada 300 ms hasta que salga. Todo se mide dentro de la página, con su reloj: con la
// máquina cargada, lo que ve Playwright llega segundos tarde.
test('al volver a la pestaña, el directo se pide en el momento', async ({ page }) => {
  await openDashboard(page);
  await page.goto('/?retraso=0');
  const { starts, beforeTick } = await page.evaluate(async () => {
    const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
    const live = () =>
      performance.getEntriesByType('resource').filter((e) => e.name.includes('/api/live')).map((e) => e.startTime);
    const giveUp = performance.now() + 20_000;
    while (live().length < 1 && performance.now() < giveUp) await sleep(100);
    const beforeTick = (live()[0] ?? 0) + 9_500;
    while (live().length < 2 && performance.now() < beforeTick + 3_000) {
      if (performance.now() < beforeTick) {
        Object.defineProperty(document, 'hidden', { configurable: true, get: () => false });
        document.dispatchEvent(new Event('visibilitychange'));
      }
      await sleep(300);
    }
    return { starts: live(), beforeTick };
  });
  expect(starts.length, 'una petición al volver').toBeGreaterThanOrEqual(2);
  expect(starts[1], 'antes del tic').toBeLessThan(beforeTick);
});

const live = /\/api\/live(\?|$)/;
const failedNotice = '[title*="No se pudo recargar"]';

// Abre el directo sin diferido y deja que `decide` conteste sus peticiones a /api/live
// desde la segunda (la del primer tic; la primera, la de montar la página, sale del HAR).
// Devuelve la hora de cada petición de esa página, que se va llenando.
async function openDeciding(page: Page, decide: (route: Route, nth: number) => Promise<void>): Promise<number[]> {
  const seen: number[] = [];
  await openDashboard(page);
  await page.route(live, async (route) => {
    if (!route.request().frame().url().includes('retraso=0')) return route.fallback();
    seen.push(Date.now());
    return seen.length === 1 ? route.fallback() : decide(route, seen.length);
  });
  await page.goto('/?retraso=0');
  await expect.poll(() => seen.length, { timeout: 30_000 }).toBeGreaterThanOrEqual(2);
  return seen;
}

// Una petición que no vuelve se da por perdida a los 35 s: hasta entonces no sale otra,
// ni con los tics ni volviendo a la pestaña; entonces sale el aviso de fallo y el tic
// siguiente pide. La tercera se retiene para que el aviso solo pueda venir del tope.
test('una petición sin respuesta se da por perdida a los 35 s y el directo vuelve a pedir', async ({ page }) => {
  test.setTimeout(120_000);
  let dropSecond = () => {};
  let answerThird = () => {};
  const second = new Promise<void>((r) => (dropSecond = r));
  const third = new Promise<void>((r) => (answerThird = r));
  const seen = await openDeciding(page, async (route, nth) => {
    if (nth === 2) {
      await second;
      return route.abort().catch(() => {});
    }
    if (nth === 3) await third;
    return route.fallback();
  });
  await expect(page.locator(failedNotice)).toHaveCount(0);
  await page.evaluate(async () => {
    const end = performance.now() + 28_000;
    while (performance.now() < end) {
      Object.defineProperty(document, 'hidden', { configurable: true, get: () => false });
      document.dispatchEvent(new Event('visibilitychange'));
      await new Promise((r) => setTimeout(r, 300));
    }
  });
  expect(seen.length, 'dentro del tope no se pide').toBe(2);
  await expect.poll(() => seen.length, { timeout: 30_000 }).toBeGreaterThanOrEqual(3);
  expect(seen[2] - seen[1], 'no antes del tope').toBeGreaterThanOrEqual(34_000);
  await expect(page.locator(failedNotice).first()).toBeAttached();
  answerThird();
  await expect(page.locator(failedNotice)).toHaveCount(0, { timeout: 15_000 });
  dropSecond();
});

test('tras un error de red, el directo pide en el tic siguiente', async ({ page }) => {
  test.setTimeout(60_000);
  const seen = await openDeciding(page, (route, nth) => (nth === 2 ? route.abort('failed') : route.fallback()));
  await expect.poll(() => seen.length, { timeout: 20_000 }).toBeGreaterThanOrEqual(3);
  expect(seen[2] - seen[1], 'en el tic siguiente').toBeLessThan(15_000);
});

// Con el diferido (41 s, como el de por defecto; `retraso=41` separa estas peticiones de las de
// `openDashboard`), un 500 desde la primera petición se dice como sin diferido; de control,
// cuando llega la primera buena las dos tarjetas pasan a la espera.
test('con el diferido, un fallo desde la carga se dice al momento; al llegar la primera buena, la espera', async ({ page }) => {
  test.setTimeout(60_000);
  let failing = true;
  await openDashboard(page);
  await page.route(live, (route) => {
    if (!failing || !route.request().frame().url().includes('retraso=41')) return route.fallback();
    return route.fulfill({ status: 500, contentType: 'text/plain', body: 'boom' });
  });
  await page.goto('/?retraso=41');
  const notices = async () => {
    const timing = await page.locator('.widget--live-timing p.status').allTextContents();
    const tyre = await page.locator('.widget--tyre-strategy p.status').allTextContents();
    return timing.length && tyre.length ? [...new Set([...timing, ...tyre])] : [];
  };
  await expect.poll(notices, { timeout: 15_000 }).toEqual(['Error al cargar /api/live']);
  failing = false;
  const waiting = /^En espera · diferido 0:41 · empieza en \d+ s$/;
  await expect.poll(async () => {
    const shown = await notices();
    return shown.length > 0 && shown.every((t) => waiting.test(t));
  }, { timeout: 20_000 }).toBe(true);
});
