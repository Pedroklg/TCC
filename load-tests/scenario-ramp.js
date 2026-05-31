// Cenário 2 — RAMPA (degradação sob crescimento gradual), Quadro 3.
// VUs crescem progressivamente até um teto, permitindo observar a degradação.
//
// Execução:
//   k6 run -e TARGET=mono -e MAX_VUS=200 load-tests/scenario-ramp.js

import { vuLoop } from './lib/workload.js';

const MAX = Number(__ENV.MAX_VUS || 200);

export const options = {
  scenarios: {
    rampa: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: __ENV.RAMP_UP || '2m', target: MAX },   // subida gradual
        { duration: __ENV.HOLD || '3m', target: MAX },       // sustenta o teto
        { duration: __ENV.RAMP_DOWN || '1m', target: 0 },    // descida
      ],
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.05'],
    http_req_duration: ['p(95)<1500'],
  },
};

export default function () {
  vuLoop();
}
