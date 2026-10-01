import type { Page } from '@playwright/test';

const recording = process.env.E2E_RECORD === '1';
const har = 'recordings/api.har';

/**
 * Abre el dashboard. Al grabar, contra el servidor vivo, guardando lo que contesta
 * `/api/*`. Si no, nada sale a la red: la página sale del frontend construido
 * (`E2E_FRONTEND`) y `/api/*` de lo grabado, y una petición que no está grabada se
 * aborta. Lo grabado solo se reproduce con el mismo `E2E_URL` con el que se grabó.
 */
export async function openDashboard(page: Page): Promise<void> {
  if (recording) {
    await page.routeFromHAR(har, { url: '**/api/**', update: true, updateContent: 'embed' });
  } else {
    const frontend = process.env.E2E_FRONTEND;
    if (!frontend) throw new Error('falta E2E_FRONTEND: lánzalo con dashboardF1-e2e');
    await page.route('**/*', (route) => {
      const { pathname } = new URL(route.request().url());
      if (pathname.includes('..')) return route.abort();
      return route.fulfill({ path: frontend + (pathname === '/' ? '/index.html' : pathname) });
    });
    await page.routeFromHAR(har, { url: '**/api/**', notFound: 'abort' });
  }
  await page.goto('/');
}
