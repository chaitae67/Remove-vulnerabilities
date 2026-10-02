package com.example.clinic.security;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.net.URI;
import java.net.URISyntaxException;
import java.util.Set;
import org.springframework.web.filter.OncePerRequestFilter;

/** CSRF 토큰과 별도로 브라우저의 교차 출처 상태 변경 요청을 거부한다. */
public class SameOriginRequestFilter extends OncePerRequestFilter {

    private static final Set<String> SAFE_METHODS = Set.of("GET", "HEAD");

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {
        if (!SAFE_METHODS.contains(request.getMethod().toUpperCase(java.util.Locale.ROOT))) {
            String source = request.getHeader("Origin");
            if (source == null || source.isBlank()) {
                source = request.getHeader("Referer");
            }
            if (source != null && !source.isBlank() && !isSameOrigin(source, request)) {
                response.sendError(HttpServletResponse.SC_FORBIDDEN, "허용되지 않은 출처의 요청입니다.");
                return;
            }
        }
        chain.doFilter(request, response);
    }

    private boolean isSameOrigin(String source, HttpServletRequest request) {
        try {
            URI uri = new URI(source);
            if (uri.getScheme() == null || uri.getHost() == null) {
                return false;
            }
            int sourcePort = effectivePort(uri.getScheme(), uri.getPort());
            int requestPort = effectivePort(request.getScheme(), request.getServerPort());
            return uri.getScheme().equalsIgnoreCase(request.getScheme())
                && uri.getHost().equalsIgnoreCase(request.getServerName())
                && sourcePort == requestPort;
        } catch (URISyntaxException exception) {
            return false;
        }
    }

    private int effectivePort(String scheme, int port) {
        if (port > 0) return port;
        return "https".equalsIgnoreCase(scheme) ? 443 : 80;
    }
}
