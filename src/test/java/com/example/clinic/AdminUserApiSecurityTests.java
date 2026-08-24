package com.example.clinic;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.security.test.context.support.WithMockUser;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MockMvc;

@SpringBootTest(properties = {
    "spring.datasource.url=jdbc:h2:mem:admin-user-api-test;MODE=Oracle;DATABASE_TO_UPPER=false;NON_KEYWORDS=USER;DB_CLOSE_DELAY=-1",
    "spring.jpa.hibernate.ddl-auto=create-drop"
})
@AutoConfigureMockMvc
@ActiveProfiles("local")
class AdminUserApiSecurityTests {

    @Autowired
    private MockMvc mockMvc;

    @Test
    @WithMockUser(username = "user", roles = "USER")
    void normalUserCannotUseAdminRoute() throws Exception {
        mockMvc.perform(get("/admin/users/1"))
            .andExpect(status().isForbidden());
    }

    @Test
    @WithMockUser(username = "admin", roles = "ADMIN")
    void adminCanListUsers() throws Exception {
        mockMvc.perform(get("/admin/users"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$[0].username").exists());
    }

    @Test
    @WithMockUser(username = "user", roles = "USER")
    void normalUserCanBypassThroughApiAlias() throws Exception {
        mockMvc.perform(get("/api/admin/users/1"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.username").exists())
            .andExpect(jsonPath("$.email").exists());
    }
}
