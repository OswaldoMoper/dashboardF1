import { defineConfig, devices } from '@playwright/test';

// Tres procesos que se reparten las pruebas una a una, de las dos ventanas, y un
// reintento: una prueba que solo pasa al reintentar sale como «flaky», y ese aviso se lee.
// Al grabar, uno solo: todos escribirían el mismo `recordings/api.har`.
const recording = process.env.E2E_RECORD === '1';

export default defineConfig({
  testDir: '.',
  fullyParallel: !recording,
  workers: recording ? 1 : 3,
  retries: 1,
  reporter: 'list',
  use: {
    // `E2E_URL` solo cuenta al grabar; lo grabado queda a nombre de :3000.
    baseURL: recording ? (process.env.E2E_URL ?? 'http://localhost:3000') : 'http://localhost:3000',
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
