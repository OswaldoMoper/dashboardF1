import { expect, test } from '@playwright/test';
import { openDashboard } from './serve';

// Tras un 500 de /api/historical, cada tarjeta vuelve a pedir a los 30 s y, si esta vez
// contesta, pinta su clasificación; hasta entonces, el error. `retraso=0` separa estas
// peticiones de las de `openDashboard`.
test('Pilotos y Constructores vuelven a pedir a los 30 s de un fallo', async ({ page }) => {
  test.setTimeout(90_000);
  const seen: number[] = [];
  await openDashboard(page);
  await page.route(/\/api\/historical(\?|$)/, (route) => {
    if (!route.request().frame().url().includes('retraso=0')) return route.fallback();
    seen.push(Date.now());
    return seen.length <= 2 ? route.fulfill({ status: 500, contentType: 'text/plain', body: 'boom' }) : route.fallback();
  });
  await page.goto('/?retraso=0');
  const cards = page.locator('.widget--driver-stats, .widget--constructor-stats');
  await expect(cards.locator('p.status--error')).toHaveCount(2, { timeout: 20_000 });
  await expect(cards.locator('table')).toHaveCount(2, { timeout: 45_000 });
  await expect(cards.locator('p.status--error')).toHaveCount(0);
  expect(seen.length, 'una petición por tarjeta y un reintento de cada una').toBe(4);
  expect(seen[2] - seen[0], 'no antes de los 30 s').toBeGreaterThanOrEqual(29_000);
});
