package com.example.clinic.controller;

import java.net.URI;
import java.net.URISyntaxException;
import java.security.Principal;
import java.time.Instant;
import java.util.Base64;
import java.util.Locale;
import java.util.Map;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;

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
    private final String adminLoginSecret;

    public GlobalModelAdvice(
            UserService userService,
            @Value("${app.admin-url:https://admin.zerodayclinic.p-e.kr:443/}") String adminUrl,
            @Value("${app.local-admin-url:http://localhost:8081/admin}") String localAdminUrl,
            @Value("${app.admin-login-secret:clinic-admin-login}") String adminLoginSecret) {
        this.userService = userService;
        this.adminUrl = adminUrl;
        this.localAdminUrl = localAdminUrl;
        this.adminLoginSecret = adminLoginSecret;
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
    public String adminUrl(HttpServletRequest request, Principal principal) {
        String targetUrl = isLocalRequest(request) ? localAdminUrl : forceHttpsPort443(adminUrl);
        if (isAdmin(principal)) {
            return appendAdminLoginTicket(targetUrl, principal.getName());
        }
        return targetUrl;
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
            return "https://admin.zerodayclinic.p-e.kr:443/admin/sso";
        }
    }

    private String appendAdminLoginTicket(String url, String username) {
        long expiresAt = Instant.now().plusSeconds(300).getEpochSecond();
        String signature = sign(username, expiresAt);
        String separator = url.contains("?") ? "&" : "?";
        return url + separator
            + "ssoUser=" + encode(username)
            + "&ssoExpires=" + expiresAt
            + "&ssoSig=" + encode(signature);
    }

    private String sign(String username, long expiresAt) {
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(adminLoginSecret.getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
            byte[] digest = mac.doFinal((username + ":" + expiresAt).getBytes(StandardCharsets.UTF_8));
            return Base64.getUrlEncoder().withoutPadding().encodeToString(digest);
        } catch (Exception ex) {
            throw new IllegalStateException("Admin login ticket could not be created.", ex);
        }
    }

    private String encode(String value) {
        return URLEncoder.encode(value, StandardCharsets.UTF_8);
    }
}
