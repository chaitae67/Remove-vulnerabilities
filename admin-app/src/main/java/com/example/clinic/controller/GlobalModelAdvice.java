package com.example.clinic.controller;

import java.security.Principal;
import java.util.Map;

import org.springframework.security.core.Authentication;
import org.springframework.security.web.csrf.CsrfToken;
import org.springframework.security.web.csrf.DefaultCsrfToken;
import org.springframework.web.bind.annotation.ControllerAdvice;
import org.springframework.web.bind.annotation.ModelAttribute;

import com.example.clinic.service.UserService;

import jakarta.servlet.http.HttpServletRequest;

@ControllerAdvice
public class GlobalModelAdvice {

    private final UserService userService;

    public GlobalModelAdvice(UserService userService) {
        this.userService = userService;
    }

    @ModelAttribute("currentUserId")
    public Long currentUserId(Principal principal) {
        if (principal == null) {
            return null;
        }
        return userService.findByUsername(principal.getName()).getId();
    }

    @ModelAttribute("isAuthenticated")
    public boolean isAuthenticated(Principal principal) {
        return principal != null;
    }

    @ModelAttribute("isAdmin")
    public boolean isAdmin(Principal principal) {
        if (principal instanceof Authentication authentication) {
            return authentication.getAuthorities().stream()
                .anyMatch(authority -> authority.getAuthority().equals("ROLE_ADMIN"));
        }
        return false;
    }

    @ModelAttribute("currentUsername")
    public String currentUsername(Principal principal) {
        return principal == null ? null : principal.getName();
    }

    @ModelAttribute("_csrf")
    public CsrfToken csrfToken(CsrfToken token) {
        if (token != null) {
            return token;
        }
        /*
         * VULNERABLE LAB:
         * SecurityConfig에서 CSRF 검증을 비활성화하면 Spring이 CsrfToken을 만들지 않는다.
         * 기존 FreeMarker 폼은 _csrf 값을 참조하므로 렌더링 오류만 피하기 위해 검증되지 않는
         * 더미 토큰을 노출한다.
         */
        return new DefaultCsrfToken("X-CSRF-TOKEN", "_csrf", "csrf-disabled");
    }

    @ModelAttribute("param")
    public Map<String, String[]> param(HttpServletRequest request) {
        return request.getParameterMap();
    }
}
