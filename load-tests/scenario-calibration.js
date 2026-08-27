// Cenário auxiliar — CALIBRAÇÃO do ponto de saturação. Não faz parte do Quadro 3:
// serve para escolher a taxa de pico da campanha definitiva com base no teto medido
// de cada arquitetura, em vez de um valor arbitrário.
//
// MODELO ABERTO em degraus: cada patamar é mantido tempo suficiente para o sistema
// estabilizar, de modo que o joelho da curva throughput × carga oferecida apareça.
// Os degraus são GEOMÉTRICOS porque os tetos das três arquiteturas podem diferir
// em ordem de grandeza, e uma progressão linear desperdiçaria resolução na faixa baixa.
//
// Sem thresholds: o objetivo é observar a degradação, não aprovar ou reprovar.

import { vuLoop } from './lib/workload.js';

const START = Number(__ENV.START_RATE || 10);
const MAX = Number(__ENV.MAX_RATE || 1000);
const STEPS = Number(__ENV.STEPS || 12);
const HOLD = __ENV.STEP_HOLD || '40s';
const RISE = __ENV.STEP_RISE || '10s';

const stages = [];
for (let i = 1; i <= STEPS; i++) {
  const target = Math.round(START * Math.pow(MAX / START, i / STEPS));
  stages.push({ duration: RISE, target });
  stages.push({ duration: HOLD, target });
}

export const options = {
  scenarios: {
    calibracao: {
      executor: 'ramping-arrival-rate',
      startRate: START,
      timeUnit: '1s',
      preAllocatedVUs: Number(__ENV.PREALLOC_VUS || 200),
      // Cada VU custa cerca de 2,4 MB com as fichas agregadas deste experimento, e
      // um teto de 3.000 esgota a memória do gerador antes de o alvo saturar. O teto
      // é o mesmo do cenário de pico, para calibrar sob a restrição de cliente que a
      // campanha vai impor; alcançá-lo aparece como dropped_iterations, que é o
      // indício correto de saturação em modelo aberto.
      maxVUs: Number(__ENV.MAX_VUS || 800),
      stages,
    },
  },
};

export default function () {
  vuLoop();
}
