// La única global de Node que lee la suite; se declara aquí para que la
// comprobación de tipos no necesite el paquete de tipos de Node.
declare const process: { env: Record<string, string | undefined> };
