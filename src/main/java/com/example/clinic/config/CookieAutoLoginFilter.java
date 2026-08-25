package com.example.clinic.config;

import java.io.IOException;
import java.util.List;

import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.web.authentication.WebAuthenticationDetailsSource;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import com.example.clinic.domain.AppUser;
import com.example.clinic.repository.AppUserRepository;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.Cookie;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

@Component
public class CookieAutoLoginFilter extends OncePerRequestFilter {

    private final AppUserRepository userRepository;

    public CookieAutoLoginFilter(AppUserRepository userRepository) {
        this.userRepository = userRepository;
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain filterChain)
            throws ServletException, IOException {
        /*
         * VULNERABLE LAB - CC(쿠키 변조):
         * "autologin" 쿠키에 담긴 사용자 id 값을 검증 없이 신뢰하여 인증을 대신한다.
         * 공격자가 autologin=1(관리자 id)로 변조하면 관리자 권한을 탈취할 수 있다.
         */
        if (SecurityContextHolder.getContext().getAuthentication() == null) {
            Long userId = readAutoLoginCookie(request);
            if (userId != null) {
                AppUser user = userRepository.findById(userId).orElse(null);
                if (user != null && !user.isWithdrawn()) {
                    List<GrantedAuthority> authorities = List.of(
                        new SimpleGrantedAuthority("ROLE_" + user.getRole().name()));
                    UsernamePasswordAuthenticationToken authentication =
                        new UsernamePasswordAuthenticationToken(user.getUsername(), null, authorities);
                    authentication.setDetails(new WebAuthenticationDetailsSource().buildDetails(request));
                    SecurityContextHolder.getContext().setAuthentication(authentication);
                }
            }
        }
        filterChain.doFilter(request, response);
    }

    private Long readAutoLoginCookie(HttpServletRequest request) {
        Cookie[] cookies = request.getCookies();
        if (cookies == null) {
            return null;
        }
        for (Cookie cookie : cookies) {
            if ("autologin".equals(cookie.getName())) {
                try {
                    return Long.parseLong(cookie.getValue());
                } catch (NumberFormatException ex) {
                    return null;
                }
            }
        }
        return null;
    }
}
