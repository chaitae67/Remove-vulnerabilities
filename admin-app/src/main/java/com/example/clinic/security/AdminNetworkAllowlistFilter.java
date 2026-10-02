package com.example.clinic.security;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.util.Arrays;
import java.util.List;
import org.springframework.security.web.util.matcher.IpAddressMatcher;
import org.springframework.web.filter.OncePerRequestFilter;

/**
 * AE-19: 관리자 애플리케이션 전체를 운영자/VPN 대역으로 제한한다.
 */
public class AdminNetworkAllowlistFilter extends OncePerRequestFilter {

    private final List<IpAddressMatcher> allowedNetworks;

    public AdminNetworkAllowlistFilter(String configuredNetworks) {
        this.allowedNetworks = Arrays.stream(configuredNetworks.split(","))
            .map(String::trim)
            .filter(value -> !value.isBlank())
            .map(IpAddressMatcher::new)
            .toList();
        if (allowedNetworks.isEmpty()) {
            throw new IllegalArgumentException("관리자 접근 허용 대역이 비어 있습니다.");
        }
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {
        boolean allowed = allowedNetworks.stream().anyMatch(matcher -> matcher.matches(request));
        if (!allowed) {
            // 관리자 서비스의 존재와 로그인 경로를 불필요하게 노출하지 않는다.
            response.sendError(HttpServletResponse.SC_NOT_FOUND);
            return;
        }
        chain.doFilter(request, response);
    }
}
