import { expect, test } from '@playwright/test';
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
