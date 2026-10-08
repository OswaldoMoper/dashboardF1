import { defineConfig, devices } from '@playwright/test';

// Un proceso por ventana, con las pruebas de cada una en orden, y un reintento: una
// prueba que solo pasa al reintentar sale como «flaky», y ese aviso se lee.
export default defineConfig({
  testDir: '.',
  workers: 2,
  retries: 1,
  reporter: 'list',
  use: {
    // `E2E_URL` solo cuenta al grabar; lo grabado queda a nombre de :3000.
    baseURL:
      process.env.E2E_RECORD === '1'
        ? (process.env.E2E_URL ?? 'http://localhost:3000')
        : 'http://localhost:3000',
    trace: 'retain-on-failure',
  },
  projects: [
    {
      name: 'edge-1912x914',
      use: { ...devices['Desktop Chrome'], viewport: { width: 1912, height: 914 } },
    },
    {
      name: 'portatil-1280x720',
      use: { ...devices['Desktop Chrome'], viewport: { width: 1280, height: 720 } },
    },
  ],
});
