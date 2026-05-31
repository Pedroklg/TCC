// Carga de trabalho compartilhada pelos três cenários (constante, rampa, pico).
//
// Simula um fluxo de uso REAL e correlacionado, e — crucialmente — exercita o
// endpoint que DIFERENCIA as arquiteturas:
//   1. lista owners (navegação)                         -> customers-service
//   2. abre a FICHA de um owner (owner + pets + visits)  -> AGREGAÇÃO
//        - monolito/serverless: resolve em processo (join no banco)
//        - microsserviços: gateway agrega customers + visits (custo de rede)
//   3. ~VISIT_RATIO das vezes, agenda uma visita em um pet daquele owner -> visits-service
//   4. reads leves ocasionais (vets, pettypes)
//   5. ~NEW_OWNER_RATIO das vezes, cadastra um owner                     -> customers-service
//   6. think time aleatório
//
// Métricas padrão do k6 cobrem a QP2 (http_req_duration p95/p99, http_reqs,
// http_req_failed). As trends abaixo isolam a operação discriminante e as escritas.

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend } from 'k6/metrics';
import { getTarget } from './targets.js';

const target = getTarget();
const base = target.baseUrl;
const r = target.routes;

export const ownerDetailLatency = new Trend('op_owner_detail_latency', true); // agregação (P1)
export const writeLatency = new Trend('op_write_latency', true);

const headers = { 'Content-Type': 'application/json' };
const VISIT_RATIO = Number(__ENV.VISIT_RATIO || 0.2);
const NEW_OWNER_RATIO = Number(__ENV.NEW_OWNER_RATIO || 0.05);
const THINK_MIN = Number(__ENV.THINK_MIN ?? 0.5);
const THINK_MAX = Number(__ENV.THINK_MAX ?? 2.0);

// O PetClinic valida nome com a regex ^[\p{L}]+([ '-][\p{L}]+){0,2}\.?$ (só letras).
function letters(n) {
  const a = 'abcdefghijklmnopqrstuvwxyz';
  let s = '';
  for (let i = 0; i < n; i++) s += a[Math.floor(Math.random() * a.length)];
  return s;
}

function thinkTime() {
  const span = Math.max(0, THINK_MAX - THINK_MIN);
  const t = THINK_MIN + Math.random() * span;
  if (t > 0) sleep(t);
}

export function vuLoop() {
  // 1) Navegação: lista de owners
  const listRes = http.get(`${base}${r.listOwners()}`, { tags: { op: 'listOwners' } });
  check(listRes, { 'listOwners 200': (res) => res.status === 200 });

  let owners = [];
  try {
    const body = listRes.json();
    owners = Array.isArray(body) ? body : (body && body.content) || [];
  } catch (e) { /* corpo inesperado */ }

  // 2) Abre a FICHA de um owner aleatório — endpoint discriminante (agregação)
  if (owners.length > 0) {
    const ownerId = owners[Math.floor(Math.random() * owners.length)].id;
    const detail = http.get(`${base}${r.ownerDetail(ownerId)}`, { tags: { op: 'ownerDetail' } });
    check(detail, {
      'ownerDetail 200': (res) => res.status === 200,
      // check de conteúdo: garante trabalho equivalente (não um 200 vazio)
      'ownerDetail traz pets': (res) => {
        try { return Array.isArray(res.json('pets')); } catch (e) { return false; }
      },
    });
    ownerDetailLatency.add(detail.timings.duration);

    // 3) Escrita realista pós-consulta: agenda visita em um pet desse owner
    let pets = [];
    try { pets = detail.json('pets') || []; } catch (e) { /* ignore */ }
    if (pets.length > 0 && Math.random() < VISIT_RATIO) {
      const petId = pets[Math.floor(Math.random() * pets.length)].id;
      const payload = JSON.stringify({ date: '2024-01-01', description: `Load test ${letters(4)}` });
      const res = http.post(`${base}${r.createVisit(ownerId, petId)}`, payload,
        { headers, tags: { op: 'createVisit' } });
      check(res, { 'createVisit 2xx': (x) => x.status >= 200 && x.status < 300 });
      writeLatency.add(res.timings.duration);
    }
  }

  // 4) Reads leves ocasionais
  if (Math.random() < 0.3) http.get(`${base}${r.listVets()}`, { tags: { op: 'listVets' } });
  if (Math.random() < 0.2) http.get(`${base}${r.listPetTypes()}`, { tags: { op: 'listPetTypes' } });

  // 5) Escrita ocasional no customers-service (cadastro de owner)
  if (Math.random() < NEW_OWNER_RATIO) {
    const payload = JSON.stringify({
      firstName: 'Load', lastName: letters(8), address: '123 Test St',
      city: 'Ponta Grossa', telephone: '0000000000',
    });
    const res = http.post(`${base}${r.createOwner()}`, payload,
      { headers, tags: { op: 'createOwner' } });
    check(res, { 'createOwner 2xx': (x) => x.status >= 200 && x.status < 300 });
    writeLatency.add(res.timings.duration);
  }

  thinkTime();
}
