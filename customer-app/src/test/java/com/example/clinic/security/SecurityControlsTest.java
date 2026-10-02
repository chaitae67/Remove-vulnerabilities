package com.example.clinic.security;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.example.clinic.util.PrivacyMasker;
import com.example.clinic.controller.SafeErrorController;
import com.example.clinic.controller.SafeExceptionHandler;
import jakarta.servlet.RequestDispatcher;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpStatus;
import org.springframework.mock.web.MockFilterChain;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;
import org.springframework.mock.web.MockMultipartFile;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;

class SecurityControlsTest {

    @Test
    void rejectsWeakLegacyPasswordEvenWhenItsBcryptHashMatches() {
        String weakHash = new BCryptPasswordEncoder().encode("user1234");
        PolicyEnforcingPasswordEncoder encoder = new PolicyEnforcingPasswordEncoder();

        assertThat(encoder.matches("user1234", weakHash)).isFalse();
        assertThat(PasswordPolicy.isStrongForUsername("Secur3!Passphrase", "user")).isTrue();
        assertThat(PasswordPolicy.isStrongForUsername("User-Strong!234", "user")).isFalse();
    }

    @Test
    void returnsMinimalSafeErrorModels() {
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/private/path");
        request.setAttribute(RequestDispatcher.ERROR_STATUS_CODE, 500);
        var errorView = new SafeErrorController().error(request);
        var badRequestView = new SafeExceptionHandler().badRequest();

        assertThat(errorView.getStatus()).isEqualTo(HttpStatus.INTERNAL_SERVER_ERROR);
        assertThat(errorView.getModel()).containsOnlyKeys("status");
        assertThat(badRequestView.getStatus()).isEqualTo(HttpStatus.BAD_REQUEST);
        assertThat(badRequestView.getModel()).containsOnlyKeys("status");
    }

    @Test
    void masksPersonalInformationOnListViews() {
        assertThat(PrivacyMasker.name("홍길동")).isEqualTo("홍*동");
        assertThat(PrivacyMasker.email("person@example.com")).isEqualTo("p***@example.com");
        assertThat(PrivacyMasker.phone("010-1234-5678")).isEqualTo("010-****-5678");
    }

    @Test
    void rejectsUnusedHttpMethods() throws Exception {
        MockHttpServletRequest request = new MockHttpServletRequest("PUT", "/support/request-diagnostics");
        MockHttpServletResponse response = new MockHttpServletResponse();
        new HttpMethodRestrictionFilter().doFilter(request, response, new MockFilterChain());
        assertThat(response.getStatus()).isEqualTo(405);
        assertThat(response.getHeader("Allow")).isEqualTo("GET, HEAD, POST");
    }

    @Test
    void rejectsHtmlDisguisedAsImage() {
        MockMultipartFile file = new MockMultipartFile("file", "payload.png", "image/png", "<script>alert(1)</script>".getBytes());
        assertThatThrownBy(() -> SecureFileValidator.validate(file, 1024))
            .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void rejectsNoticeWriteEvenWhenAUserChangesAnotherFormAction() throws Exception {
        MockHttpServletRequest request = new MockHttpServletRequest("POST", "/notices");
        request.setServletPath("/notices");
        MockHttpServletResponse response = new MockHttpServletResponse();
        new CustomerNoticeWriteProtectionFilter().doFilter(request, response, new MockFilterChain());
        assertThat(response.getStatus()).isEqualTo(403);
    }

    @Test
    void rejectsCrossSiteStateChangingRequest() throws Exception {
        MockHttpServletRequest request = new MockHttpServletRequest("POST", "/reviews");
        request.setServerName("www.example.com");
        request.setServerPort(443);
        request.setScheme("https");
        request.addHeader("Origin", "https://attacker.example");
        MockHttpServletResponse response = new MockHttpServletResponse();
        new SameOriginRequestFilter().doFilter(request, response, new MockFilterChain());
        assertThat(response.getStatus()).isEqualTo(403);
    }

    @Test
    void rateLimitsRepeatedLoginAttempts() throws Exception {
        RateLimitFilter filter = new RateLimitFilter();
        MockHttpServletResponse response = null;
        for (int i = 0; i < 6; i++) {
            MockHttpServletRequest request = new MockHttpServletRequest("POST", "/login");
            request.setServletPath("/login");
            request.setRemoteAddr("192.0.2.10");
            request.addParameter("username", "user");
            response = new MockHttpServletResponse();
            filter.doFilter(request, response, new MockFilterChain());
        }
        assertThat(response).isNotNull();
        assertThat(response.getStatus()).isEqualTo(429);
        assertThat(response.getHeader("Retry-After")).isEqualTo("60");
    }

    @Test
    void rateLimitsSameAccountEvenWhenRemoteAddressChanges() throws Exception {
        RateLimitFilter filter = new RateLimitFilter();
        MockHttpServletResponse response = null;
        for (int i = 0; i < 6; i++) {
            MockHttpServletRequest request = new MockHttpServletRequest("POST", "/login");
            request.setServletPath("/login");
            request.setRemoteAddr("198.51.100." + (i + 1));
            request.addParameter("username", "target-user");
            response = new MockHttpServletResponse();
            filter.doFilter(request, response, new MockFilterChain());
        }
        assertThat(response).isNotNull();
        assertThat(response.getStatus()).isEqualTo(429);
    }

    @Test
    void rateLimitsCredentialStuffingFromOneAddress() throws Exception {
        RateLimitFilter filter = new RateLimitFilter();
        MockHttpServletResponse response = null;
        for (int i = 0; i < 31; i++) {
            MockHttpServletRequest request = new MockHttpServletRequest("POST", "/login");
            request.setServletPath("/login");
            request.setRemoteAddr("192.0.2.20");
            request.addParameter("username", "candidate-" + i);
            response = new MockHttpServletResponse();
            filter.doFilter(request, response, new MockFilterChain());
        }
        assertThat(response).isNotNull();
        assertThat(response.getStatus()).isEqualTo(429);
    }
}
