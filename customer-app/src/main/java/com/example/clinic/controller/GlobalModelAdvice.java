package com.example.clinic.controller;

import java.net.URI;
import java.net.URISyntaxException;
import java.security.Principal;
import java.util.Locale;
import java.util.Map;

import org.springframework.security.core.Authentication;
import org.springframework.security.web.csrf.CsrfToken;
import org.springframework.security.web.csrf.DefaultCsrfToken;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.ControllerAdvice;
import org.springframework.web.bind.annotation.ModelAttribute;

import com.example.clinic.service.UserService;

import jakarta.servlet.http.HttpServletRequest;

@ControllerAdvice
public class GlobalModelAdvice {

    private final UserService userService;
    private final String adminUrl;
    private final String localAdminUrl;

    public GlobalModelAdvice(
            UserService userService,
            @Value("${app.admin-url:https://admin.zerodayclinic.p-e.kr:443/}") String adminUrl,
            @Value("${app.local-admin-url:http://localhost:8081/admin}") String localAdminUrl) {
        this.userService = userService;
        this.adminUrl = adminUrl;
        this.localAdminUrl = localAdminUrl;
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

    @ModelAttribute("adminUrl")
    public String adminUrl(HttpServletRequest request) {
        if (isLocalRequest(request)) {
            return localAdminUrl;
        }
        return forceHttpsPort443(adminUrl);
    }

    @ModelAttribute("_csrf")
    public CsrfToken csrfToken(CsrfToken token) {
        if (token != null) {
            return token;
        }
        return new DefaultCsrfToken("X-CSRF-TOKEN", "_csrf", "csrf-disabled");
    }

    @ModelAttribute("param")
    public Map<String, String[]> param(HttpServletRequest request) {
        return request.getParameterMap();
    }

    private boolean isLocalRequest(HttpServletRequest request) {
        String host = request.getServerName();
        if (host == null) {
            return false;
        }
        String normalizedHost = host.toLowerCase(Locale.ROOT);
        return normalizedHost.equals("localhost")
            || normalizedHost.equals("127.0.0.1")
            || normalizedHost.equals("0:0:0:0:0:0:0:1")
            || normalizedHost.equals("::1");
    }

    private String forceHttpsPort443(String url) {
        try {
            URI uri = new URI(url);
            String path = uri.getPath();
            return new URI("https", uri.getUserInfo(), uri.getHost(), 443,
                path == null || path.isBlank() ? "/" : path,
                uri.getQuery(), uri.getFragment()).toString();
        } catch (URISyntaxException | IllegalArgumentException ex) {
            return "https://admin.zerodayclinic.p-e.kr:443/";
        }
    }
}
