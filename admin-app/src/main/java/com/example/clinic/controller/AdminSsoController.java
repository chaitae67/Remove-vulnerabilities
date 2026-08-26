package com.example.clinic.controller;

import com.example.clinic.domain.AppUser;
import com.example.clinic.domain.Role;
import com.example.clinic.repository.AppUserRepository;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
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
import org.springframework.stereotype.Controller;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;

@Controller
public class AdminSsoController {

    private final AppUserRepository userRepository;
    private final String adminLoginSecret;
    private final HttpSessionSecurityContextRepository securityContextRepository = new HttpSessionSecurityContextRepository();

    public AdminSsoController(
            AppUserRepository userRepository,
            @Value("${app.admin-login-secret:clinic-admin-login}") String adminLoginSecret) {
        this.userRepository = userRepository;
        this.adminLoginSecret = adminLoginSecret;
    }

    @GetMapping("/admin/sso")
    public String loginFromCustomer(
            @RequestParam(name = "ssoUser", required = false) String username,
            @RequestParam(name = "ssoExpires", required = false) String expires,
            @RequestParam(name = "ssoSig", required = false) String signature,
            HttpServletRequest request,
            HttpServletResponse response) {
        if (username == null || expires == null || signature == null) {
            return "redirect:/login";
        }

        long expiresAt;
        try {
            expiresAt = Long.parseLong(expires);
        } catch (NumberFormatException ex) {
            return "redirect:/login";
        }

        if (expiresAt < Instant.now().getEpochSecond() || !signatureMatches(username, expiresAt, signature)) {
            return "redirect:/login";
        }

        return userRepository.findByUsername(username)
            .filter(user -> user.getRole() == Role.ADMIN)
            .filter(user -> !user.isWithdrawn())
            .map(user -> {
                saveAdminSession(user, request, response);
                return "redirect:/admin";
            })
            .orElse("redirect:/login");
    }

    private void saveAdminSession(AppUser user, HttpServletRequest request, HttpServletResponse response) {
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
        securityContextRepository.saveContext(context, request, response);
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
