// Cenário 3 — PICO / ESTRESSE (resiliência e ponto de saturação), Quadro 3.
//
// MODELO ABERTO (ramping-arrival-rate): mantém uma TAXA DE CHEGADA alvo
// independentemente da velocidade do sistema. Diferente do modelo fechado
// (constant-vus), aqui a carga oferecida NÃO se auto-limita quando o sistema fica
// lento — a fila cresce e a saturação aparece de verdade (latência dispara, erros
// surgem, k6 pode acusar VUs insuficientes). É a forma adequada de achar o teto.
//
// Obs.: "rate" = ITERAÇÕES por segundo; cada iteração faz ~2-4 requisições
// (lista + ficha agregada + reads/escritas eventuais). O think time é ZERO aqui
// (run-all.ps1 passa THINK_MIN=0/THINK_MAX=0), pois o modelo aberto controla a chegada.
//
// Execução:
//   k6 run -e TARGET=mono -e PEAK_RATE=300 -e THINK_MIN=0 -e THINK_MAX=0 load-tests/scenario-spike.js

import { vuLoop } from './lib/workload.js';

const BASE = Number(__ENV.BASE_RATE || 20);   // iter/s em regime base
const PEAK = Number(__ENV.PEAK_RATE || 300);  // iter/s no pico

export const options = {
  scenarios: {
    pico: {
      executor: 'ramping-arrival-rate',
      startRate: BASE,
      timeUnit: '1s',
      preAllocatedVUs: Number(__ENV.PREALLOC_VUS || 100),
      maxVUs: Number(__ENV.MAX_VUS || 800),
      stages: [
        { duration: __ENV.PRE || '30s', target: BASE },        // base estável
        { duration: __ENV.RISE || '10s', target: PEAK },       // PICO abrupto
        { duration: __ENV.PEAK_HOLD || '1m', target: PEAK },   // sustenta o pico
        { duration: __ENV.FALL || '10s', target: BASE },       // recuo
        { duration: __ENV.POST || '30s', target: 0 },          // recuperação
      ],
    },
  },
  thresholds: {
    // Sob estresse esperamos degradação; o objetivo é IDENTIFICAR a saturação,
    // não passar/falhar. Limiar tolerante.
    http_req_failed: ['rate<0.25'],
  },
};

export default function () {
  vuLoop();
}
