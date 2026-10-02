package com.example.clinic.security;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.util.Set;
import org.springframework.http.HttpHeaders;
import org.springframework.web.filter.OncePerRequestFilter;

/**
 * WM-21: 애플리케이션이 실제 사용하는 HTTP 메서드만 허용한다.
 */
public class HttpMethodRestrictionFilter extends OncePerRequestFilter {

    private static final Set<String> ALLOWED_METHODS = Set.of("GET", "HEAD", "POST");

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {
        if (!ALLOWED_METHODS.contains(request.getMethod().toUpperCase(java.util.Locale.ROOT))) {
            response.setStatus(HttpServletResponse.SC_METHOD_NOT_ALLOWED);
            response.setHeader(HttpHeaders.ALLOW, "GET, HEAD, POST");
            response.setContentType("text/plain;charset=UTF-8");
            response.getWriter().write("허용되지 않는 요청 방식입니다.");
            return;
        }
        chain.doFilter(request, response);
    }
}
