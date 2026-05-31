package org.springframework.samples.petclinic.serverless;

import java.util.Map;
import java.util.function.Function;

import com.amazonaws.services.lambda.runtime.events.APIGatewayProxyRequestEvent;
import com.amazonaws.services.lambda.runtime.events.APIGatewayProxyResponseEvent;
import tools.jackson.core.JacksonException;
import tools.jackson.databind.ObjectMapper;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.samples.petclinic.mapper.OwnerMapper;
import org.springframework.samples.petclinic.mapper.PetTypeMapper;
import org.springframework.samples.petclinic.mapper.VetMapper;
import org.springframework.samples.petclinic.mapper.VisitMapper;
import org.springframework.samples.petclinic.model.Owner;
import org.springframework.samples.petclinic.model.Visit;
import org.springframework.samples.petclinic.rest.dto.OwnerFieldsDto;
import org.springframework.samples.petclinic.rest.dto.VisitFieldsDto;
import org.springframework.samples.petclinic.service.ClinicService;

/**
 * Funções de responsabilidade única (FaaS) que reusam a fachada de domínio
 * {@link ClinicService} e os mappers do monolito, garantindo respostas JSON
 * idênticas às da versão monolítica. Cada bean é implantado como uma função Lambda
 * independente, selecionada por {@code spring.cloud.function.definition} no template.
 */
@Configuration
public class LambdaConfig {

    private final ClinicService clinicService;
    private final OwnerMapper ownerMapper;
    private final VetMapper vetMapper;
    private final PetTypeMapper petTypeMapper;
    private final VisitMapper visitMapper;
    private final ObjectMapper objectMapper;

    public LambdaConfig(ClinicService clinicService, OwnerMapper ownerMapper, VetMapper vetMapper,
                        PetTypeMapper petTypeMapper, VisitMapper visitMapper, ObjectMapper objectMapper) {
        this.clinicService = clinicService;
        this.ownerMapper = ownerMapper;
        this.vetMapper = vetMapper;
        this.petTypeMapper = petTypeMapper;
        this.visitMapper = visitMapper;
        this.objectMapper = objectMapper;
    }

    // ---- Leituras ----

    @Bean
    public Function<APIGatewayProxyRequestEvent, APIGatewayProxyResponseEvent> getAllOwners() {
        return req -> json(200, ownerMapper.toOwnerDtoCollection(clinicService.findAllOwners()));
    }

    @Bean
    public Function<APIGatewayProxyRequestEvent, APIGatewayProxyResponseEvent> getOwnerById() {
        return req -> {
            Integer id = pathInt(req, "ownerId");
            if (id == null) {
                return json(400, Map.of("error", "ownerId ausente"));
            }
            Owner owner = clinicService.findOwnerById(id);
            if (owner == null) {
                return json(404, Map.of("error", "owner não encontrado"));
            }
            return json(200, ownerMapper.toOwnerDto(owner)); // owner + pets + visits
        };
    }

    @Bean
    public Function<APIGatewayProxyRequestEvent, APIGatewayProxyResponseEvent> listVets() {
        return req -> json(200, vetMapper.toVetDtos(clinicService.findVets()));
    }

    @Bean
    public Function<APIGatewayProxyRequestEvent, APIGatewayProxyResponseEvent> listPetTypes() {
        return req -> json(200, petTypeMapper.toPetTypeDtos(clinicService.findPetTypes()));
    }

    // ---- Escritas ----

    @Bean
    public Function<APIGatewayProxyRequestEvent, APIGatewayProxyResponseEvent> createOwner() {
        return req -> {
            try {
                OwnerFieldsDto fields = objectMapper.readValue(req.getBody(), OwnerFieldsDto.class);
                Owner owner = ownerMapper.toOwner(fields);
                clinicService.saveOwner(owner);
                return json(201, ownerMapper.toOwnerDto(owner));
            } catch (JacksonException e) {
                return json(400, Map.of("error", "corpo inválido"));
            }
        };
    }

    @Bean
    public Function<APIGatewayProxyRequestEvent, APIGatewayProxyResponseEvent> createVisit() {
        return req -> {
            Integer petId = pathInt(req, "petId");
            if (petId == null) {
                return json(400, Map.of("error", "petId ausente"));
            }
            try {
                VisitFieldsDto fields = objectMapper.readValue(req.getBody(), VisitFieldsDto.class);
                Visit visit = visitMapper.toVisit(fields);
                visit.setPet(clinicService.findPetById(petId));
                clinicService.saveVisit(visit);
                return json(201, visitMapper.toVisitDto(visit));
            } catch (JacksonException e) {
                return json(400, Map.of("error", "corpo inválido"));
            }
        };
    }

    // ---- Helpers ----

    private Integer pathInt(APIGatewayProxyRequestEvent req, String name) {
        Map<String, String> params = req.getPathParameters();
        if (params == null || params.get(name) == null) {
            return null;
        }
        try {
            return Integer.valueOf(params.get(name));
        } catch (NumberFormatException e) {
            return null;
        }
    }

    private APIGatewayProxyResponseEvent json(int status, Object body) {
        APIGatewayProxyResponseEvent res = new APIGatewayProxyResponseEvent()
            .withStatusCode(status)
            .withHeaders(Map.of("Content-Type", "application/json"));
        try {
            return res.withBody(objectMapper.writeValueAsString(body));
        } catch (JacksonException e) {
            return res.withStatusCode(500).withBody("{\"error\":\"serialização\"}");
        }
    }
}
