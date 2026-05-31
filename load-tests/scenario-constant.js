// Cenário 1 — CARGA CONSTANTE (regime estável), Quadro 3 da metodologia.
// Número fixo de VUs por um período determinado.
//
// Execução:
//   k6 run -e TARGET=mono -e VUS=50 -e DURATION=5m load-tests/scenario-constant.js

import { vuLoop } from './lib/workload.js';

export const options = {
  scenarios: {
    constante: {
      executor: 'constant-vus',
      vus: Number(__ENV.VUS || 50),
      duration: __ENV.DURATION || '5m',
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],            // < 1% de erro em regime estável
    http_req_duration: ['p(95)<500', 'p(99)<1000'],
  },
};

export default function () {
  vuLoop();
}
