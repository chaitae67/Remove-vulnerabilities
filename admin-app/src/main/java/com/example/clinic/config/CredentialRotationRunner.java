package com.example.clinic.config;

import com.example.clinic.domain.AppUser;
import com.example.clinic.repository.AppUserRepository;
import com.example.clinic.security.PasswordPolicy;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.core.annotation.Order;

/**
 * BF-09 운영 전환 도구. 명시적으로 활성화된 한 번의 기동에서만 기존 테스트 계정의
 * 비밀번호를 강한 값으로 교체한다. 적용 후 반드시 활성화 플래그와 비밀번호 환경변수를 제거한다.
 */
@Component
@Order(100)
public class CredentialRotationRunner implements ApplicationRunner {

    private final AppUserRepository userRepository;
    private final PasswordEncoder passwordEncoder;
    private final boolean enabled;
    private final String adminPassword;
    private final String userPassword;

    public CredentialRotationRunner(
        AppUserRepository userRepository,
        PasswordEncoder passwordEncoder,
        @Value("${app.security.rotate-passwords-on-startup:false}") boolean enabled,
        @Value("${app.security.rotation-admin-password:}") String adminPassword,
        @Value("${app.security.rotation-user-password:}") String userPassword
    ) {
        this.userRepository = userRepository;
        this.passwordEncoder = passwordEncoder;
        this.enabled = enabled;
        this.adminPassword = adminPassword;
        this.userPassword = userPassword;
    }

    @Override
    @Transactional
    public void run(ApplicationArguments args) {
        if (!enabled) return;
        rotate("admin", adminPassword);
        rotate("user", userPassword);
    }

    private void rotate(String username, String rawPassword) {
        PasswordPolicy.requireStrong(rawPassword, username);
        AppUser user = userRepository.findByUsername(username)
            .orElseThrow(() -> new IllegalStateException("비밀번호 교체 대상 계정을 찾을 수 없습니다."));
        user.setPassword(passwordEncoder.encode(rawPassword));
        userRepository.save(user);
    }
}
