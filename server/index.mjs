import { createApp } from './app.mjs';
import { createNemotron } from './nemotron.mjs';

const host = process.env.HOST ?? '127.0.0.1';
const port = Number(process.env.PORT ?? 8787);
if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('PORT must be between 1 and 65535.');
const server = createApp({
  clientToken: process.env.RAY_GUARDIAN_CLIENT_TOKEN,
  configured: Boolean(process.env.VERDA_INFERENCE_KEY),
  analyze: createNemotron({
    apiKey: process.env.VERDA_INFERENCE_KEY,
    baseURL: process.env.VERDA_BASE_URL,
    model: process.env.VERDA_MODEL,
  }),
});
server.listen(port, host, () => console.log(`Ray Guardian AI listening on ${host}:${port}`));
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close(() => process.exit(0)));
