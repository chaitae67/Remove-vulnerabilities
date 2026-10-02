package com.example.clinic.service;

import com.example.clinic.domain.AppUser;
import com.example.clinic.domain.Role;
import com.example.clinic.repository.AppUserRepository;
import java.security.Principal;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;

/**
 * IA-10: 금전·권한·상품 상태에 영향을 주는 관리자 작업 직전에 비밀번호를 다시 확인한다.
 */
@Service
public class AdminReauthenticationService {

    private final AppUserRepository userRepository;
    private final PasswordEncoder passwordEncoder;

    public AdminReauthenticationService(AppUserRepository userRepository, PasswordEncoder passwordEncoder) {
        this.userRepository = userRepository;
        this.passwordEncoder = passwordEncoder;
    }

    public void verify(Principal principal, String rawPassword) {
        if (principal == null || rawPassword == null || rawPassword.isBlank()) {
            throw new IllegalArgumentException("관리자 비밀번호를 다시 입력해 주세요.");
        }
        AppUser administrator = userRepository.findByUsername(principal.getName())
            .filter(user -> user.getRole() == Role.ADMIN && !user.isWithdrawn())
            .orElseThrow(() -> new IllegalArgumentException("관리자 재인증에 실패했습니다."));
        if (!passwordEncoder.matches(rawPassword, administrator.getPassword())) {
            throw new IllegalArgumentException("관리자 재인증에 실패했습니다.");
        }
    }
}
