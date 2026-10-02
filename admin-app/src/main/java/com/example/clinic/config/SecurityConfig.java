package com.example.clinic.config;

import com.example.clinic.repository.AppUserRepository;
import com.example.clinic.domain.Role;
import com.example.clinic.security.AdminNetworkAllowlistFilter;
import com.example.clinic.security.HttpMethodRestrictionFilter;
import com.example.clinic.security.RateLimitFilter;
import com.example.clinic.security.SameOriginRequestFilter;
import com.example.clinic.security.PolicyEnforcingPasswordEncoder;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.authentication.dao.DaoAuthenticationProvider;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
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
    private final AdminNetworkAllowlistFilter adminNetworkAllowlistFilter;
    private final boolean requireHttps;

    public SecurityConfig(
            @Value("${app.admin.allowed-networks:127.0.0.1/32,::1/128}") String allowedNetworks,
            @Value("${app.security.require-https:true}") boolean requireHttps) {
        this.adminNetworkAllowlistFilter = new AdminNetworkAllowlistFilter(allowedNetworks);
        this.requireHttps = requireHttps;
    }

    @Bean
    SecurityFilterChain securityFilterChain(HttpSecurity http) throws Exception {
        http
            .authorizeHttpRequests(auth -> auth
                .requestMatchers("/", "/login", "/css/**", "/js/**", "/images/**", "/error").permitAll()
                .requestMatchers("/admin/**", "/api/admin/**").hasRole("ADMIN")
                .anyRequest().denyAll())
            .formLogin(form -> form
                .loginPage("/login")
                .defaultSuccessUrl("/admin", true)
                .permitAll())
            .logout(logout -> logout
                .logoutRequestMatcher(new AntPathRequestMatcher("/logout", "POST"))
                .logoutSuccessUrl("/login?logout")
                .invalidateHttpSession(true)
                .deleteCookies("JSESSIONID")
                .permitAll())
            // IS-16: 로그인 시 세션 ID를 재발급하여 세션 고정 공격을 차단한다.
            .sessionManagement(session -> session
                .sessionCreationPolicy(SessionCreationPolicy.IF_REQUIRED)
                .sessionFixation(fixation -> fixation.changeSessionId()))
            // CF-07: CSRF 보호를 활성화한다.
            .csrf(csrf -> {})
            // SN-17/XS-06: 보안 응답 헤더(전송구간 보안·클릭재킹·스니핑 방지).
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
            .addFilterBefore(adminNetworkAllowlistFilter, UsernamePasswordAuthenticationFilter.class)
            // WM-21: CSRF 판정보다 먼저 메서드를 거부해 일관된 405 응답을 반환한다.
            .addFilterBefore(httpMethodRestrictionFilter, CsrfFilter.class)
            .addFilterBefore(sameOriginRequestFilter, CsrfFilter.class)
            .addFilterBefore(rateLimitFilter, UsernamePasswordAuthenticationFilter.class);

        if (requireHttps) {
            http.requiresChannel(channel -> channel.anyRequest().requiresSecure());
        }

        return http.build();
    }

    @Bean
    UserDetailsService userDetailsService(AppUserRepository userRepository) {
        return username -> userRepository.findByUsername(username)
            // AE-19: 일반 회원 계정은 관리자 애플리케이션에서 인증할 수 없다.
            .filter(user -> user.getRole() == Role.ADMIN)
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
