package com.example.clinic;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestBuilders.formLogin;
import static org.springframework.security.test.web.servlet.response.SecurityMockMvcResultMatchers.unauthenticated;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.flash;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.redirectedUrl;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.example.clinic.repository.AppUserRepository;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.security.test.context.support.WithMockUser;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MockMvc;

@SpringBootTest(properties = {
    "spring.datasource.url=jdbc:h2:mem:user-withdrawal-test;MODE=Oracle;DATABASE_TO_UPPER=false;NON_KEYWORDS=USER;DB_CLOSE_DELAY=-1",
    "spring.jpa.hibernate.ddl-auto=create-drop",
    "app.chatbot.ai.enabled=false"
})
@AutoConfigureMockMvc
@ActiveProfiles("local")
class UserWithdrawalTests {

    @Autowired
    private MockMvc mockMvc;

    @Autowired
    private AppUserRepository userRepository;

    @Test
    @WithMockUser(username = "user", roles = "USER")
    void withdrawalMarksUserAndLogsOut() throws Exception {
        mockMvc.perform(post("/mypage/withdraw")
                .with(csrf())
                .param("password", "user1234"))
            .andExpect(status().is3xxRedirection())
            .andExpect(redirectedUrl("/"))
            .andExpect(flash().attribute("message", "회원 탈퇴가 완료되었습니다."));

        var withdrawnUser = userRepository.findByUsername("user").orElseThrow();
        assertThat(withdrawnUser.isWithdrawn()).isTrue();
        assertThat(withdrawnUser.getWithdrawnAt()).isNotNull();

        mockMvc.perform(formLogin().user("user").password("user1234"))
            .andExpect(unauthenticated());
    }

    @Test
    @WithMockUser(username = "admin", roles = "ADMIN")
    void wrongPasswordDoesNotWithdrawUser() throws Exception {
        mockMvc.perform(post("/mypage/withdraw")
                .with(csrf())
                .param("password", "wrong-password"))
            .andExpect(status().is3xxRedirection())
            .andExpect(redirectedUrl("/mypage?userId=1"))
            .andExpect(flash().attribute("withdrawError", "비밀번호가 일치하지 않습니다."));

        assertThat(userRepository.findByUsername("admin").orElseThrow().isWithdrawn()).isFalse();
    }
}
