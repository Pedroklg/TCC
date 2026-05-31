package org.springframework.samples.petclinic.serverless;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.function.Function;

import com.amazonaws.services.lambda.runtime.events.APIGatewayProxyRequestEvent;
import com.amazonaws.services.lambda.runtime.events.APIGatewayProxyResponseEvent;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.ApplicationContext;

/**
 * Valida o wiring: o contexto sobe (sem a camada web do monolito), os repositórios
 * Spring Data conectam ao MySQL e as funções produzem respostas equivalentes.
 * Requer o MySQL compartilhado de pé e semeado (porta 3306).
 */
@SpringBootTest
class WiringTest {

    @Autowired
    ApplicationContext ctx;

    @SuppressWarnings("unchecked")
    private Function<APIGatewayProxyRequestEvent, APIGatewayProxyResponseEvent> fn(String name) {
        return (Function<APIGatewayProxyRequestEvent, APIGatewayProxyResponseEvent>) ctx.getBean(name);
    }

    @Test
    void getAllOwners_returnsSeededData() {
        APIGatewayProxyResponseEvent res = fn("getAllOwners").apply(new APIGatewayProxyRequestEvent());
        assertThat(res.getStatusCode()).isEqualTo(200);
        assertThat(res.getBody()).contains("George"); // owner semeado (George Franklin)
    }

    @Test
    void getOwnerById_aggregatesPetsAndVisits() {
        APIGatewayProxyRequestEvent req = new APIGatewayProxyRequestEvent()
            .withPathParameters(java.util.Map.of("ownerId", "1"));
        APIGatewayProxyResponseEvent res = fn("getOwnerById").apply(req);
        assertThat(res.getStatusCode()).isEqualTo(200);
        assertThat(res.getBody()).contains("\"pets\""); // ficha traz pets (e visitas)
    }

    @Test
    void listVets_and_listPetTypes_work() {
        assertThat(fn("listVets").apply(new APIGatewayProxyRequestEvent()).getStatusCode()).isEqualTo(200);
        assertThat(fn("listPetTypes").apply(new APIGatewayProxyRequestEvent()).getStatusCode()).isEqualTo(200);
    }
}
