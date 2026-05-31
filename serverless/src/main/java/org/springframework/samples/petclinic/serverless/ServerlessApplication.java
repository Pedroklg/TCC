package org.springframework.samples.petclinic.serverless;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.persistence.autoconfigure.EntityScan;
import org.springframework.data.jpa.repository.config.EnableJpaRepositories;

/**
 * Aplicação serverless do PetClinic.
 *
 * Reúsa o domínio do monolito (service, mapper, model, repository) como biblioteca,
 * expondo-o como funções spring-cloud-function (ver {@link LambdaConfig}). NÃO sobe a
 * camada web/segurança do monolito — apenas a fachada de domínio e a persistência.
 */
@SpringBootApplication(scanBasePackages = {
    "org.springframework.samples.petclinic.serverless",
    "org.springframework.samples.petclinic.service",
    "org.springframework.samples.petclinic.mapper"
})
@EntityScan("org.springframework.samples.petclinic.model")
@EnableJpaRepositories("org.springframework.samples.petclinic.repository.springdatajpa")
public class ServerlessApplication {

    public static void main(String[] args) {
        SpringApplication.run(ServerlessApplication.class, args);
    }
}
