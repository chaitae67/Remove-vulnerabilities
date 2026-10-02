package com.example.clinic.security;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;

import com.example.clinic.repository.ProcedureProductRepository;
import com.example.clinic.repository.ProcedureSearchRepository;
import com.example.clinic.service.ProcedureService;
import com.example.clinic.service.NoticeService;
import com.example.clinic.repository.NoticeRepository;
import com.example.clinic.domain.AppUser;
import com.example.clinic.domain.Role;
import com.example.clinic.controller.SafeErrorController;
import com.example.clinic.controller.SafeExceptionHandler;
import jakarta.servlet.RequestDispatcher;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpStatus;
import org.springframework.mock.web.MockFilterChain;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;

class AdminSecurityControlsTest {

    @Test
    void rejectsWeakLegacyPasswordEvenWhenItsBcryptHashMatches() {
        String weakHash = new BCryptPasswordEncoder().encode("admin1234");
        PolicyEnforcingPasswordEncoder encoder = new PolicyEnforcingPasswordEncoder();

        assertThat(encoder.matches("admin1234", weakHash)).isFalse();
        assertThat(PasswordPolicy.isStrongForUsername("Secur3!Passphrase", "admin")).isTrue();
        assertThat(PasswordPolicy.isStrongForUsername("Admin-Strong!234", "admin")).isFalse();
    }

    @Test
    void returnsMinimalSafeErrorModels() {
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/admin/private/path");
        request.setAttribute(RequestDispatcher.ERROR_STATUS_CODE, 404);
        var errorView = new SafeErrorController().error(request);
        var forbiddenView = new SafeExceptionHandler().forbidden();

        assertThat(errorView.getStatus()).isEqualTo(HttpStatus.NOT_FOUND);
        assertThat(errorView.getModel()).containsOnlyKeys("status");
        assertThat(forbiddenView.getStatus()).isEqualTo(HttpStatus.FORBIDDEN);
        assertThat(forbiddenView.getModel()).containsOnlyKeys("status");
    }

    @Test
    void rejectsTraceAndPut() throws Exception {
        for (String method : new String[]{"TRACE", "PUT", "DELETE", "CONNECT", "OPTIONS"}) {
            MockHttpServletResponse response = new MockHttpServletResponse();
            new HttpMethodRestrictionFilter().doFilter(
                new MockHttpServletRequest(method, "/admin"), response, new MockFilterChain());
            assertThat(response.getStatus()).isEqualTo(405);
        }
    }

    @Test
    void rejectsXxeDocumentBeforePersistence() {
        ProcedureService service = new ProcedureService(
            mock(ProcedureProductRepository.class), mock(ProcedureSearchRepository.class));
        String xml = "<!DOCTYPE x [<!ENTITY leak SYSTEM 'file:///etc/passwd'>]><procedures><procedure><name>&leak;</name></procedure></procedures>";
        assertThatThrownBy(() -> service.importFromXml(xml))
            .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void noticeServiceRejectsNonAdminAuthor() {
        NoticeService service = new NoticeService(mock(NoticeRepository.class));
        AppUser user = new AppUser();
        user.setRole(Role.USER);
        assertThatThrownBy(() -> service.create("공지", "내용", null, user))
            .isInstanceOf(IllegalArgumentException.class)
            .hasMessageContaining("관리자만");
    }

    @Test
    void adminAllowlistIgnoresUntrustedForwardedForHeader() throws Exception {
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/login");
        request.setRemoteAddr("203.0.113.10");
        request.addHeader("X-Forwarded-For", "127.0.0.1");
        MockHttpServletResponse response = new MockHttpServletResponse();

        new AdminNetworkAllowlistFilter("127.0.0.1/32")
            .doFilter(request, response, new MockFilterChain());

        assertThat(response.getStatus()).isEqualTo(404);
    }

    @Test
    void rateLimitsSameAdminAccountEvenWhenRemoteAddressChanges() throws Exception {
        RateLimitFilter filter = new RateLimitFilter();
        MockHttpServletResponse response = null;
        for (int i = 0; i < 6; i++) {
            MockHttpServletRequest request = new MockHttpServletRequest("POST", "/login");
            request.setServletPath("/login");
            request.setRemoteAddr("198.51.100." + (i + 1));
            request.addParameter("username", "admin-target");
            response = new MockHttpServletResponse();
            filter.doFilter(request, response, new MockFilterChain());
        }
        assertThat(response).isNotNull();
        assertThat(response.getStatus()).isEqualTo(429);
    }
}
