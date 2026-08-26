package com.example.clinic.service;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.Optional;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

@Component
public class OllamaChatClient {

    private static final Logger log = LoggerFactory.getLogger(OllamaChatClient.class);

    private final ObjectMapper objectMapper;
    private final HttpClient httpClient;
    private final boolean enabled;
    private final String model;
    private final URI endpoint;

    public OllamaChatClient(
        ObjectMapper objectMapper,
        @Value("${app.chatbot.ai.enabled:true}") boolean enabled,
        @Value("${app.chatbot.ai.model:gemma3:1b}") String model,
        @Value("${app.chatbot.ai.endpoint:http://localhost:11434/api/chat}") String endpoint
    ) {
        this.objectMapper = objectMapper;
        this.enabled = enabled;
        this.model = model;
        this.endpoint = URI.create(endpoint);
        this.httpClient = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(3))
            .build();
    }

    public boolean isEnabled() {
        return enabled;
    }

    public Optional<String> ask(String prompt) {
        if (!enabled) {
            return Optional.empty();
        }

        try {
            ObjectNode requestJson = objectMapper.createObjectNode();
            requestJson.put("model", model);
            requestJson.put("stream", false);
            requestJson.put("think", false);

            ArrayNode messages = requestJson.putArray("messages");
            messages.addObject()
                .put("role", "user")
                .put("content", prompt);
            requestJson.putObject("options").put("num_predict", 600);

            HttpRequest request = HttpRequest.newBuilder(endpoint)
                .timeout(Duration.ofSeconds(120))
                .header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(requestJson.toString()))
                .build();

            HttpResponse<String> response = httpClient.send(
                request,
                HttpResponse.BodyHandlers.ofString()
            );
            if (response.statusCode() < 200 || response.statusCode() >= 300) {
                log.warn("Ollama API 호출 실패: HTTP {} (model={})", response.statusCode(), model);
                return Optional.empty();
            }

            JsonNode root = objectMapper.readTree(response.body());
            String answer = root.path("message").path("content").asText();
            if (answer.isBlank()) {
                log.warn("Ollama API 응답에 출력 텍스트가 없습니다. (model={})", model);
                return Optional.empty();
            }
            return Optional.of(answer);
        } catch (Exception exception) {
            log.warn(
                "Ollama 연결 실패. Ollama 실행 및 모델 설치를 확인하세요: {}: {}",
                exception.getClass().getSimpleName(),
                exception.getMessage()
            );
            return Optional.empty();
        }
    }
}
