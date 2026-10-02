package com.example.clinic.security;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;
import org.springframework.web.filter.OncePerRequestFilter;

/**
 * AU-20: 관리자 로그인 등에 대한 자동화 공격을 IP와 계정 단위로 제한한다.
 * (SecurityConfig에서 직접 생성해 시큐리티 필터 체인에만 등록한다.)
 */
public class RateLimitFilter extends OncePerRequestFilter {

    private static final int MAX_LOGIN_REQUESTS_PER_ACCOUNT_PER_MINUTE = 5;
    private static final int MAX_LOGIN_REQUESTS_PER_IP_PER_MINUTE = 20;
    private static final int MAX_ADMIN_MUTATIONS_PER_MINUTE = 20;
    private static final int MAX_COUNTERS = 10_000;
    private static final long WINDOW_MILLIS = 60_000L;

    private final Map<String, Window> counters = new ConcurrentHashMap<>();

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {
        if (isRateLimited(request)) {
            long now = System.currentTimeMillis();
            if (counters.size() >= MAX_COUNTERS) {
                counters.entrySet().removeIf(entry -> now - entry.getValue().start > WINDOW_MILLIS);
            }
            if (counters.size() >= MAX_COUNTERS) {
                reject(response);
                return;
            }

            String path = request.getServletPath();
            String ip = clientIp(request);
            boolean exceeded;
            if ("/login".equals(path)) {
                String account = normalizedAccount(request.getParameter("username"));
                exceeded = incrementAndExceeded("login-ip|" + ip, now, MAX_LOGIN_REQUESTS_PER_IP_PER_MINUTE)
                    | incrementAndExceeded("login-account|" + account, now,
                        MAX_LOGIN_REQUESTS_PER_ACCOUNT_PER_MINUTE);
            } else {
                exceeded = incrementAndExceeded("admin-mutation|" + ip, now,
                    MAX_ADMIN_MUTATIONS_PER_MINUTE);
            }
            if (exceeded) {
                reject(response);
                return;
            }
        }
        chain.doFilter(request, response);
    }

    private boolean incrementAndExceeded(String key, long now, int limit) {
        Window window = counters.compute(key, (ignored, existing) -> {
            if (existing == null || now - existing.start > WINDOW_MILLIS) {
                return new Window(now);
            }
            existing.count.incrementAndGet();
            return existing;
        });
        return window.count.get() > limit;
    }

    private void reject(HttpServletResponse response) throws IOException {
        response.setStatus(429);
        response.setHeader("Retry-After", "60");
        response.setContentType("text/plain;charset=UTF-8");
        response.getWriter().write("요청이 너무 많습니다. 잠시 후 다시 시도해 주세요.");
    }

    private boolean isRateLimited(HttpServletRequest request) {
        return "POST".equalsIgnoreCase(request.getMethod())
            && ("/login".equals(request.getServletPath()) || request.getServletPath().startsWith("/admin/"));
    }

    private String clientIp(HttpServletRequest request) {
        // native RemoteIpValve가 신뢰 프록시 체인을 검증한 뒤 정규화한 값만 사용한다.
        return request.getRemoteAddr();
    }

    private String normalizedAccount(String username) {
        if (username == null) return "<empty>";
        String normalized = username.trim().toLowerCase(java.util.Locale.ROOT);
        return normalized.length() <= 128 ? normalized : normalized.substring(0, 128);
    }

    private static final class Window {
        private final long start;
        private final AtomicInteger count = new AtomicInteger(1);

        private Window(long start) {
            this.start = start;
        }
    }
}
