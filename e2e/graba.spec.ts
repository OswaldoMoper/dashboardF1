import { expect, test } from '@playwright/test';
import { openDashboard } from './serve';

// Lo único que corre `dashboardF1-e2e-record`: una carga de la página, que es lo que
// piden todas las pruebas al abrirla. Una petición que alguna prueba necesite y no salga
// al cargar se pide aquí; sin grabar, la suite aborta lo que no está en `api.har`.
test('graba lo que pide la página al cargar', async ({ page }) => {
  await openDashboard(page);
  await expect(page.locator('.widget--comparison')).toBeVisible();
  await page.waitForLoadState('networkidle');
});
