package com.example.clinic.config;

import com.example.clinic.repository.AppUserRepository;
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

@Configuration
@EnableWebSecurity
public class SecurityConfig {

    @Bean
    SecurityFilterChain securityFilterChain(HttpSecurity http) throws Exception {
        http
            .authorizeHttpRequests(auth -> auth
                .requestMatchers("/", "/search", "/clinic", "/eye", "/nose", "/contour", "/lifting", "/body", "/aftercare", "/events",
                    "/login", "/register", "/forgot-password", "/reset-password", "/api/chat", "/css/**", "/js/**", "/images/**", "/uploads/**", "/error").permitAll()
                // 관리자 전용 변경 기능은 고객 WAS에서 아예 접근하지 못하게 막는다.
                .requestMatchers("/admin/**", "/api/admin/**", "/notices/new", "/notices/*/edit", "/notices/*/delete", "/notices/fetch-image", "/qna/*/answer").denyAll()
                .requestMatchers("/qna/new", "/qna/preview", "/reviews/preview", "/payments/**", "/mypage/**").authenticated()
                .requestMatchers("/procedures", "/procedures/*", "/notices", "/notices/*", "/qna", "/qna/*", "/qna/*/attachments/*", "/consultations").permitAll()
                // 취약점 진단 실습을 위해 기존 프로젝트의 리뷰 인증 누락 설정을 유지한다.
                .requestMatchers("/reviews/**").permitAll()
                .anyRequest().authenticated())
            .formLogin(form -> form
                .loginPage("/login")
                // 기존 실습 취약점(Open Redirect)을 고객 앱에 유지한다.
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
            // 취약점 진단 실습용 기존 설정 유지
            .requiresChannel(channel -> channel.anyRequest().requiresInsecure())
            .sessionManagement(session -> session.sessionFixation(sessionFixation -> sessionFixation.none()))
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
