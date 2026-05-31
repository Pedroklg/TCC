// Mapeia operações lógicas para os caminhos reais de cada arquitetura.
// As três versões do PetClinic expõem rotas diferentes; aqui isolamos essa
// diferença para que os cenários de carga sejam idênticos entre os alvos.
//
// Selecione o alvo com a variável de ambiente TARGET (mono | micro | serverless).
// Sobrescreva a URL base com BASE_URL quando estiver medindo a AWS.

const targets = {
  // Monolito: spring-petclinic-rest (context-path /petclinic/, porta 9966)
  mono: {
    baseUrl: __ENV.BASE_URL || 'http://localhost:9966/petclinic/api',
    routes: {
      listOwners: () => `/owners`,
      getOwner: (id) => `/owners/${id}`,
      // Ficha completa do owner (owner + pets + visits). No monolito resolve-se
      // em processo, com join no banco — é o lado "barato" da comparação.
      ownerDetail: (id) => `/owners/${id}`,
      listVets: () => `/vets`,
      listPetTypes: () => `/pettypes`,
      createOwner: () => `/owners`,
      createVisit: (ownerId, petId) => `/owners/${ownerId}/pets/${petId}/visits`,
    },
  },

  // Microsserviços: acesso SEMPRE pelo API Gateway (porta 8080), nunca direto.
  micro: {
    baseUrl: __ENV.BASE_URL || 'http://localhost:8080/api',
    routes: {
      listOwners: () => `/customer/owners`,
      getOwner: (id) => `/customer/owners/${id}`,
      // Ficha completa via AGREGAÇÃO no gateway: customers-service (owner+pets)
      // + visits-service (visitas). É aqui que os microsserviços pagam o custo
      // de comunicação entre serviços — o lado "caro" da comparação.
      ownerDetail: (id) => `/gateway/owners/${id}`,
      listVets: () => `/vet/vets`,
      listPetTypes: () => `/customer/petTypes`,
      createOwner: () => `/customer/owners`,
      createVisit: (ownerId, petId) => `/visit/owners/${ownerId}/pets/${petId}/visits`,
    },
  },

  // Serverless (FaaS): domínio refatorado em funções via spring-cloud-function,
  // exposto pelo API Gateway. As rotas REST espelham as do monolito (mesmas
  // operações de domínio), então reusamos o mapa do monolito; só muda a URL base.
  //   - local (sam local start-api): http://127.0.0.1:3000/api
  //   - AWS: defina BASE_URL com o endpoint de invocação do API Gateway (.../api)
  serverless: {
    baseUrl: __ENV.BASE_URL || 'http://127.0.0.1:3000/api',
    routes: null, // preenchido abaixo (reusa as do monolito)
  },
};
targets.serverless.routes = targets.mono.routes;

export function getTarget() {
  const name = (__ENV.TARGET || 'mono').toLowerCase();
  const t = targets[name];
  if (!t) {
    throw new Error(`TARGET inválido: "${name}" (use mono | micro | serverless)`);
  }
  return { name, baseUrl: t.baseUrl, routes: t.routes };
}
