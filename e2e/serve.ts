import type { Page } from '@playwright/test';

const har = 'recordings/api.har';

/**
 * Abre el dashboard sin salir a la red: la página sale del frontend construido
 * (`E2E_FRONTEND`) y `/api/*` del HAR que escribe `dashboardF1-e2e-datos`; una petición
 * que no está en el HAR se aborta.
 */
export async function openDashboard(page: Page): Promise<void> {
  const frontend = process.env.E2E_FRONTEND;
  if (!frontend) throw new Error('falta E2E_FRONTEND: lánzalo con dashboardF1-e2e');
  await page.route('**/*', (route) => {
    const { pathname } = new URL(route.request().url());
    if (pathname.includes('..')) return route.abort();
    return route.fulfill({ path: frontend + (pathname === '/' ? '/index.html' : pathname) });
  });
  await page.routeFromHAR(har, { url: '**/api/**', notFound: 'abort' });
  await page.goto('/');
}
