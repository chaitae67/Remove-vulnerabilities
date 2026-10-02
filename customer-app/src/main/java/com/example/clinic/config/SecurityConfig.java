package com.example.clinic.config;

import com.example.clinic.repository.AppUserRepository;
import com.example.clinic.domain.Role;
import com.example.clinic.security.HttpMethodRestrictionFilter;
import com.example.clinic.security.CustomerNoticeWriteProtectionFilter;
import com.example.clinic.security.RateLimitFilter;
import com.example.clinic.security.SameOriginRequestFilter;
import com.example.clinic.security.PolicyEnforcingPasswordEncoder;
import org.springframework.http.HttpMethod;
import org.springframework.context.annotation.Bean;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.authentication.dao.DaoAuthenticationProvider;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.core.userdetails.UserDetailsService;
import org.springframework.security.core.userdetails.UsernameNotFoundException;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.authentication.UsernamePasswordAuthenticationFilter;
import org.springframework.security.web.csrf.CsrfFilter;
import org.springframework.security.web.util.matcher.AntPathRequestMatcher;

@Configuration
@EnableWebSecurity
public class SecurityConfig {

    private final RateLimitFilter rateLimitFilter = new RateLimitFilter();
    private final HttpMethodRestrictionFilter httpMethodRestrictionFilter = new HttpMethodRestrictionFilter();
    private final SameOriginRequestFilter sameOriginRequestFilter = new SameOriginRequestFilter();
    private final CustomerNoticeWriteProtectionFilter customerNoticeWriteProtectionFilter = new CustomerNoticeWriteProtectionFilter();
    private final boolean requireHttps;

    public SecurityConfig(@Value("${app.security.require-https:true}") boolean requireHttps) {
        this.requireHttps = requireHttps;
    }

    @Bean
    SecurityFilterChain securityFilterChain(HttpSecurity http) throws Exception {
        http
            .authorizeHttpRequests(auth -> auth
                // 고객 서버의 공지는 읽기 전용이다. 다른 폼의 요청 경로를 /notices로 바꿔도 쓰기 권한을 주지 않는다.
                .requestMatchers(HttpMethod.POST, "/notices", "/notices/**").denyAll()
                .requestMatchers("/", "/search", "/clinic", "/eye", "/nose", "/contour", "/lifting", "/body", "/aftercare", "/events",
                    "/login", "/register", "/forgot-password", "/reset-password", "/api/chat", "/css/**", "/js/**", "/images/**",
                    "/error").permitAll()
                .requestMatchers("/admin/**", "/api/admin/**").denyAll()
                .requestMatchers("/qna/new", "/qna/preview", "/reviews/preview", "/reviews/new", "/reviews/*/edit", "/reviews/*/delete",
                    "/payments/**", "/mypage/**").hasRole("USER")
                .requestMatchers(org.springframework.http.HttpMethod.POST, "/reviews").hasRole("USER")
                .requestMatchers(HttpMethod.GET, "/notices", "/notices/**").permitAll()
                .requestMatchers("/procedures", "/procedures/*", "/qna", "/qna/*", "/qna/*/attachments/*", "/consultations").permitAll()
                .requestMatchers("/reviews", "/reviews/*", "/reviews/*/attachments/*").permitAll()
                // 고객 앱의 비공개 기능은 인증 여부만이 아니라 고객 역할까지 확인한다.
                .anyRequest().hasRole("USER"))
            .formLogin(form -> form
                .loginPage("/login")
                .successHandler((request, response, authentication) -> {
                    // AE-19: 다른 인증 공급자가 추가되더라도 관리자 권한으로 고객 앱 세션을 만들지 않는다.
                    if (!isCustomer(authentication)) {
                        if (request.getSession(false) != null) {
                            request.getSession(false).invalidate();
                        }
                        SecurityContextHolder.clearContext();
                        response.sendRedirect("/login?error");
                        return;
                    }
                    // IA-10: 오픈 리다이렉트 방지. 동일 사이트의 상대 경로만 허용한다.
                    String redirectUrl = request.getParameter("redirect");
                    if (isSafeRedirect(redirectUrl)) {
                        response.sendRedirect(redirectUrl);
                    } else {
                        response.sendRedirect("/");
                    }
                })
                .permitAll())
            .logout(logout -> logout
                .logoutRequestMatcher(new AntPathRequestMatcher("/logout", "POST"))
                .logoutSuccessUrl("/")
                .invalidateHttpSession(true)
                .deleteCookies("JSESSIONID")
                .permitAll())
            // IS-16: 로그인 시 세션 ID를 재발급하여 세션 고정 공격을 차단한다.
            .sessionManagement(session -> session
                .sessionCreationPolicy(SessionCreationPolicy.IF_REQUIRED)
                .sessionFixation(fixation -> fixation.changeSessionId()))
            // CF-07: CSRF 보호를 활성화한다(폼/AJAX는 _csrf 토큰을 전송).
            .csrf(csrf -> {})
            // SN-17/XS-06: 전송구간 보안 및 클릭재킹·스니핑 방지를 위한 보안 응답 헤더.
            .headers(headers -> headers
                .frameOptions(frame -> frame.deny())
                .contentTypeOptions(contentType -> {})
                .httpStrictTransportSecurity(hsts -> hsts
                    .includeSubDomains(true)
                    .maxAgeInSeconds(31536000))
                .referrerPolicy(referrer -> referrer
                    .policy(org.springframework.security.web.header.writers.ReferrerPolicyHeaderWriter.ReferrerPolicy.SAME_ORIGIN))
                .contentSecurityPolicy(csp -> csp.policyDirectives(
                    "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; "
                    + "script-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'none'; form-action 'self'")))
            // WM-21: CSRF 판정보다 먼저 메서드를 거부해 일관된 405 응답을 반환한다.
            .addFilterBefore(httpMethodRestrictionFilter, CsrfFilter.class)
            .addFilterBefore(sameOriginRequestFilter, CsrfFilter.class)
            .addFilterBefore(customerNoticeWriteProtectionFilter, CsrfFilter.class)
            .addFilterBefore(rateLimitFilter, UsernamePasswordAuthenticationFilter.class);

        if (requireHttps) {
            http.requiresChannel(channel -> channel.anyRequest().requiresSecure());
        }

        return http.build();
    }

    private static boolean isSafeRedirect(String url) {
        if (url == null || url.isBlank()) {
            return false;
        }
        // 절대 URL, 스킴 상대 URL(//host), 백슬래시 우회는 모두 거부한다.
        return url.startsWith("/") && !url.startsWith("//") && !url.contains("\\") && !url.contains(":");
    }

    private static boolean isCustomer(Authentication authentication) {
        boolean customerRole = authentication.getAuthorities().stream()
            .anyMatch(authority -> "ROLE_USER".equals(authority.getAuthority()));
        boolean adminRole = authentication.getAuthorities().stream()
            .anyMatch(authority -> "ROLE_ADMIN".equals(authority.getAuthority()));
        return customerRole && !adminRole;
    }

    @Bean
    UserDetailsService userDetailsService(AppUserRepository userRepository) {
        return username -> userRepository.findByUsername(username)
            // AE-19: 관리자 계정은 고객 애플리케이션에서 인증할 수 없다.
            .filter(user -> user.getRole() == Role.USER)
            .map(user -> org.springframework.security.core.userdetails.User
                .withUsername(user.getUsername())
                .password(user.getPassword())
                .roles(user.getRole().name())
                .disabled(user.isWithdrawn())
                .build())
            .orElseThrow(() -> new UsernameNotFoundException("사용자를 찾을 수 없습니다."));
    }

    @Bean
    DaoAuthenticationProvider authenticationProvider(UserDetailsService userDetailsService, PasswordEncoder passwordEncoder) {
        DaoAuthenticationProvider provider = new DaoAuthenticationProvider();
        provider.setUserDetailsService(userDetailsService);
        provider.setPasswordEncoder(passwordEncoder);
        return provider;
    }

    @Bean
    PasswordEncoder passwordEncoder() {
        return new PolicyEnforcingPasswordEncoder();
    }
}
