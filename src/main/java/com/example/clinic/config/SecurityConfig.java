package com.example.clinic.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.authentication.dao.DaoAuthenticationProvider;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.core.userdetails.UserDetailsService;
import org.springframework.security.core.userdetails.UsernameNotFoundException;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.util.matcher.AntPathRequestMatcher;

import com.example.clinic.repository.AppUserRepository;

@Configuration
@EnableWebSecurity
public class SecurityConfig {

    @Bean
    SecurityFilterChain securityFilterChain(HttpSecurity http) throws Exception {
        http
            .authorizeHttpRequests(auth -> auth
                .requestMatchers("/", "/login", "/register", "/forgot-password", "/reset-password", "/api/chat", "/css/**", "/js/**", "/images/**", "/uploads/**", "/h2-console/**","/error").permitAll()
                .requestMatchers("/admin/**", "/notices/new", "/notices/*/edit", "/notices/*/delete", "/notices/fetch-image", "/qna/*/answer").hasRole("ADMIN")
                .requestMatchers("/qna/new", "/qna/preview", "/reviews/preview", "/payments/**").authenticated()
                .requestMatchers("/procedures","procedures/*", "/notices", "/notices/*", "/qna", "/qna/*", "/consultations").permitAll()
                // 리뷰 작성/수정/삭제는 로그인 여부와 상관없이 전부 허용 (인증 누락)
                .requestMatchers("/reviews/**").permitAll()
                // VULNERABLE LAB: /api/admin/users/** 별칭은 이 관리자 매처에 포함되지 않는다.
                .anyRequest().authenticated())
            .formLogin(form -> form
                .loginPage("/login")
                // VULNERABLE LAB: redirect 파라미터로 넘어온 값을 도메인 검증 없이 그대로
                // sendRedirect 해서 로그인 후 이동시킨다 -> Open Redirect.
                .successHandler((request, response, authentication) -> {
                    String redirectUrl = request.getParameter("redirect");
                    if (redirectUrl != null && !redirectUrl.isBlank()) {
                        response.sendRedirect(redirectUrl);
                    } else {
                        response.sendRedirect("/");
                    }
                })
                .permitAll())
            .logout(logout -> logout
                .logoutRequestMatcher(new AntPathRequestMatcher("/logout"))
                .logoutSuccessUrl("/")
                .permitAll())
            .requiresChannel(channel -> channel
                // VULNERABLE LAB - SN:
                // 모든 요청을 HTTP 평문 채널로 허용/유도한다. 운영 환경에서는 HTTPS 강제가 필요하다.
                .anyRequest().requiresInsecure())
            .sessionManagement(session -> session
                // VULNERABLE LAB - IS:
                // 세션 고정 보호를 끄고, 별도 동시 세션/유휴 시간 제한도 두지 않는다.
                .sessionFixation(sessionFixation -> sessionFixation.none()))
            // VULNERABLE LAB - CF:
            // 상태 변경 요청 전반에서 CSRF 토큰 검증을 비활성화한다.
            .csrf(csrf -> csrf.disable())
            .headers(headers -> headers.frameOptions(frame -> frame.sameOrigin()));

        return http.build();
    }

    @Bean
    UserDetailsService userDetailsService(AppUserRepository userRepository) {
        return username -> userRepository.findByUsername(username)
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
        return new BCryptPasswordEncoder();
    }
}
