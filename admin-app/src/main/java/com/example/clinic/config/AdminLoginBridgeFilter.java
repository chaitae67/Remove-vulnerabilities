package com.example.clinic.config;

import com.example.clinic.domain.AppUser;
import com.example.clinic.domain.Role;
import com.example.clinic.repository.AppUserRepository;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.Base64;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContext;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.core.userdetails.User;
import org.springframework.security.core.userdetails.UserDetails;
import org.springframework.security.web.authentication.WebAuthenticationDetailsSource;
import org.springframework.security.web.context.HttpSessionSecurityContextRepository;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

@Component
public class AdminLoginBridgeFilter extends OncePerRequestFilter {

    private final AppUserRepository userRepository;
    private final String adminLoginSecret;

    public AdminLoginBridgeFilter(
            AppUserRepository userRepository,
            @Value("${app.admin-login-secret:clinic-admin-login}") String adminLoginSecret) {
        this.userRepository = userRepository;
        this.adminLoginSecret = adminLoginSecret;
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain filterChain)
            throws ServletException, IOException {
        if (SecurityContextHolder.getContext().getAuthentication() == null) {
            authenticateFromCustomerTicket(request);
        }
        filterChain.doFilter(request, response);
    }

    private void authenticateFromCustomerTicket(HttpServletRequest request) {
        String username = request.getParameter("ssoUser");
        String expires = request.getParameter("ssoExpires");
        String signature = request.getParameter("ssoSig");

        if (username == null || expires == null || signature == null) {
            return;
        }

        long expiresAt;
        try {
            expiresAt = Long.parseLong(expires);
        } catch (NumberFormatException ex) {
            return;
        }

        if (expiresAt < Instant.now().getEpochSecond() || !signatureMatches(username, expiresAt, signature)) {
            return;
        }

        userRepository.findByUsername(username)
            .filter(user -> user.getRole() == Role.ADMIN)
            .filter(user -> !user.isWithdrawn())
            .ifPresent(user -> setAdminAuthentication(request, user));
    }

    private void setAdminAuthentication(HttpServletRequest request, AppUser user) {
        UserDetails principal = User.withUsername(user.getUsername())
            .password(user.getPassword())
            .roles(user.getRole().name())
            .disabled(user.isWithdrawn())
            .build();

        UsernamePasswordAuthenticationToken authentication = new UsernamePasswordAuthenticationToken(
            principal, null, principal.getAuthorities());
        authentication.setDetails(new WebAuthenticationDetailsSource().buildDetails(request));

        SecurityContext context = SecurityContextHolder.createEmptyContext();
        context.setAuthentication(authentication);
        SecurityContextHolder.setContext(context);
        request.getSession(true).setAttribute(HttpSessionSecurityContextRepository.SPRING_SECURITY_CONTEXT_KEY, context);
    }

    private boolean signatureMatches(String username, long expiresAt, String signature) {
        return MessageDigest.isEqual(
            sign(username, expiresAt).getBytes(StandardCharsets.UTF_8),
            signature.getBytes(StandardCharsets.UTF_8));
    }

    private String sign(String username, long expiresAt) {
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(adminLoginSecret.getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
            byte[] digest = mac.doFinal((username + ":" + expiresAt).getBytes(StandardCharsets.UTF_8));
            return Base64.getUrlEncoder().withoutPadding().encodeToString(digest);
        } catch (Exception ex) {
            throw new IllegalStateException("Admin login ticket could not be verified.", ex);
        }
    }
}
