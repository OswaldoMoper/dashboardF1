import { expect, test } from '@playwright/test';
import { openDashboard } from './serve';

// El retraso aplicado en el campo pasa a la dirección y se recuerda al recargar. Un
// `?retraso=` en la dirección manda sobre lo recordado y no lo pisa; sin él, la dirección
// pasa a decir el retraso vigente al abrir.
test('el retraso del campo sobrevive a recargar', async ({ page }) => {
  await openDashboard(page);
  const field = page.locator('.delay-field__input');
  await expect(field).toHaveValue('0:41');
  await expect(page).toHaveURL(/\/\?retraso=0:41$/);

  await field.fill('2:00');
  await field.press('Enter');
  await expect(page).toHaveURL(/\/\?retraso=2:00$/);

  await page.goto('/');
  await expect(field).toHaveValue('2:00');
  await expect(page).toHaveURL(/\/\?retraso=2:00$/);

  await page.goto('/?retraso=1:30');
  await expect(field).toHaveValue('1:30');
  await expect(page).toHaveURL(/\/\?retraso=1:30$/);

  await page.goto('/');
  await expect(field).toHaveValue('2:00');
});
