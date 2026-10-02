package com.example.clinic.security;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.util.Set;
import org.springframework.web.filter.OncePerRequestFilter;

/** 고객 애플리케이션의 공지 엔드포인트를 영구적으로 읽기 전용으로 유지한다. */
public class CustomerNoticeWriteProtectionFilter extends OncePerRequestFilter {

    private static final Set<String> READ_METHODS = Set.of("GET", "HEAD");

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {
        String path = request.getServletPath();
        boolean noticePath = "/notices".equals(path) || path.startsWith("/notices/");
        if (noticePath && !READ_METHODS.contains(request.getMethod().toUpperCase(java.util.Locale.ROOT))) {
            response.sendError(HttpServletResponse.SC_FORBIDDEN, "고객 페이지에서는 공지사항을 변경할 수 없습니다.");
            return;
        }
        chain.doFilter(request, response);
    }
}
