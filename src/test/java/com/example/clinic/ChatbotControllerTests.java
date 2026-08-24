package com.example.clinic;

import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MockMvc;

@SpringBootTest(properties = {
    "spring.datasource.url=jdbc:h2:mem:chatbot-test;MODE=Oracle;DATABASE_TO_UPPER=false;NON_KEYWORDS=USER;DB_CLOSE_DELAY=-1",
    "spring.jpa.hibernate.ddl-auto=create-drop"
})
@AutoConfigureMockMvc
@ActiveProfiles("local")
class ChatbotControllerTests {

    @Autowired
    private MockMvc mockMvc;

    @Test
    void anonymousUserCanAskAboutPoints() throws Exception {
        mockMvc.perform(post("/api/chat")
                .with(csrf())
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"message\":\"포인트 사용 방법 알려줘\"}"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.answer").value(org.hamcrest.Matchers.containsString("보유 포인트")));
    }

    @Test
    void medicalDiagnosisQuestionShowsSafetyNotice() throws Exception {
        mockMvc.perform(post("/api/chat")
                .with(csrf())
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"message\":\"수술 가능한지 진단해줘\"}"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.answer").value(org.hamcrest.Matchers.containsString("의료진 상담")));
    }

    @Test
    void blankQuestionIsRejected() throws Exception {
        mockMvc.perform(post("/api/chat")
                .with(csrf())
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"message\":\"   \"}"))
            .andExpect(status().isBadRequest());
    }

    @Test
    void unknownQuestionIsReflectedWithoutHtmlEscaping() throws Exception {
        mockMvc.perform(post("/api/chat")
                .with(csrf())
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"message\":\"<img src=x onerror=alert(1)>\"}"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.answer").value(
                org.hamcrest.Matchers.containsString("<img src=x onerror=alert(1)>")
            ));
    }
}
