package com.example.clinic;

import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.security.test.context.support.WithMockUser;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MockMvc;

@SpringBootTest(properties = {
    "spring.datasource.url=jdbc:h2:mem:user-ssti-test;MODE=Oracle;DATABASE_TO_UPPER=false;NON_KEYWORDS=USER;DB_CLOSE_DELAY=-1",
    "spring.jpa.hibernate.ddl-auto=create-drop",
    "app.chatbot.ai.enabled=false"
})
@AutoConfigureMockMvc
@ActiveProfiles("local")
class UserContentPreviewSstiTests {

    @Autowired
    private MockMvc mockMvc;

    @Test
    void anonymousUserCannotUseQnaPreview() throws Exception {
        mockMvc.perform(post("/qna/preview")
                .with(csrf())
                .param("title", "테스트")
                .param("content", "일반 문의"))
            .andExpect(status().is3xxRedirection());
    }

    @Test
    @WithMockUser(username = "user", roles = "USER")
    void qnaPreviewEvaluatesUserTemplateOnServer() throws Exception {
        mockMvc.perform(post("/qna/preview")
                .with(csrf())
                .param("title", "SSTI 테스트")
                .param("content", "SSTI 계산 결과: ${7 * 7}"))
            .andExpect(status().isOk())
            .andExpect(content().string(org.hamcrest.Matchers.containsString(
                "SSTI 계산 결과: 49"
            )));
    }

    @Test
    @WithMockUser(username = "user", roles = "USER")
    void reviewPreviewEvaluatesUserTemplateOnServer() throws Exception {
        mockMvc.perform(post("/reviews/preview")
                .with(csrf())
                .param("title", "후기 SSTI 테스트")
                .param("rating", "5")
                .param("content", "SSTI 계산 결과: ${7 * 7}"))
            .andExpect(status().isOk())
            .andExpect(content().string(org.hamcrest.Matchers.containsString(
                "SSTI 계산 결과: 49"
            )));
    }
}
