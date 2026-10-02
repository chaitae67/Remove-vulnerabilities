package com.example.clinic.service;

import com.example.clinic.domain.AppUser;
import com.example.clinic.domain.Role;
import com.example.clinic.repository.AppUserRepository;
import com.example.clinic.security.PasswordPolicy;
import jakarta.transaction.Transactional;
import java.security.SecureRandom;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Optional;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;

@Service
public class UserService {

    private final AppUserRepository userRepository;
    private final PasswordEncoder passwordEncoder;
    private final SecureRandom secureRandom = new SecureRandom();

    public UserService(AppUserRepository userRepository, PasswordEncoder passwordEncoder) {
        this.userRepository = userRepository;
        this.passwordEncoder = passwordEncoder;
    }

    // BF-09: 비밀번호 정책 검증.
    private void validatePasswordPolicy(String rawPassword, String username) {
        PasswordPolicy.requireStrong(rawPassword, username);
    }

    @Transactional
    public AppUser register(String username, String rawPassword, String name, String email, String phone) {
        if (userRepository.existsByUsername(username)) {
            throw new IllegalArgumentException("이미 사용 중인 아이디입니다.");
        }
        if (userRepository.existsByEmail(email)) {
            throw new IllegalArgumentException("이미 가입된 이메일입니다.");
        }
        validatePasswordPolicy(rawPassword, username);

        AppUser user = new AppUser();
        user.setUsername(username);
        user.setPassword(passwordEncoder.encode(rawPassword));
        user.setName(name);
        user.setEmail(email);
        user.setPhone(phone);
        user.setRole(Role.USER);
        return userRepository.save(user);
    }

    public AppUser findByUsername(String username) {
        return userRepository.findByUsername(username)
            .orElseThrow(() -> new IllegalArgumentException("사용자를 찾을 수 없습니다."));
    }

    public AppUser findById(Long id) {
        return userRepository.findById(id)
            .orElseThrow(() -> new IllegalArgumentException("사용자를 찾을 수 없습니다."));
    }

    public void verifyPassword(String username, String rawPassword) {
        AppUser user = findByUsername(username);
        if (rawPassword == null || rawPassword.isBlank()
                || user.isWithdrawn()
                || !passwordEncoder.matches(rawPassword, user.getPassword())) {
            throw new IllegalArgumentException("비밀번호가 일치하지 않습니다.");
        }
    }

    public List<AppUser> findAllUsers() {
        return userRepository.findAll();
    }

    @Transactional
    public AppUser updateProfile(String username, String currentPassword, AppUser form) {
        AppUser user = findByUsername(username);
        if (currentPassword == null || currentPassword.isBlank()
                || !passwordEncoder.matches(currentPassword, user.getPassword())) {
            throw new IllegalArgumentException("현재 비밀번호가 일치하지 않습니다.");
        }
        if (form.getName() == null || form.getName().isBlank() || form.getName().trim().length() > 80) {
            throw new IllegalArgumentException("이름을 올바르게 입력해 주세요.");
        }
        if (form.getEmail() == null || form.getEmail().isBlank() || form.getEmail().trim().length() > 160) {
            throw new IllegalArgumentException("이메일을 올바르게 입력해 주세요.");
        }
        userRepository.findByEmail(form.getEmail().trim())
            .filter(other -> !other.getId().equals(user.getId()))
            .ifPresent(other -> { throw new IllegalArgumentException("이미 다른 회원이 사용 중인 이메일입니다."); });
        user.setName(form.getName().trim());
        user.setEmail(form.getEmail().trim());
        user.setPhone(form.getPhone() == null || form.getPhone().isBlank() ? null : form.getPhone().trim());
        if (form.getPassword() != null && !form.getPassword().isBlank()) {
            validatePasswordPolicy(form.getPassword(), user.getUsername());
            user.setPassword(passwordEncoder.encode(form.getPassword()));
        }
        // IN-11: 권한(role)은 회원정보 수정 시 절대 요청 값으로 변경하지 않는다(권한 상승 방지).
        return userRepository.save(user);
    }

    @Transactional
    public String issuePasswordResetToken(String username, String email) {
        Optional<AppUser> found = userRepository.findByUsernameAndEmail(username, email);
        if (found.isEmpty()) {
            return null;
        }
        AppUser user = found.get();
        // PR-12: 예측 가능한 값(시각) 대신 암호학적으로 안전한 난수 토큰을 사용한다.
        String token = generateSecureToken(32);
        user.setResetToken(token);
        user.setResetTokenExpiresAt(LocalDateTime.now().plusMinutes(30));
        return token;
    }

    // PR-12: 재설정 토큰 - URL-safe 난수 문자열.
    private String generateSecureToken(int byteLength) {
        byte[] bytes = new byte[byteLength];
        secureRandom.nextBytes(bytes);
        return java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
    }

    @Transactional
    public void resetPassword(String token, String newPassword) {
        AppUser user = userRepository.findByResetToken(token)
            .orElseThrow(() -> new IllegalArgumentException("유효하지 않거나 만료된 링크입니다."));
        if (user.getResetTokenExpiresAt() == null || user.getResetTokenExpiresAt().isBefore(LocalDateTime.now())) {
            throw new IllegalArgumentException("유효하지 않거나 만료된 링크입니다.");
        }
        validatePasswordPolicy(newPassword, user.getUsername());
        user.setPassword(passwordEncoder.encode(newPassword));
        user.setResetToken(null);
        user.setResetTokenExpiresAt(null);
    }

    @Transactional
    public void withdraw(String username, String rawPassword) {
        AppUser user = findByUsername(username);
        if (user.getRole() == Role.ADMIN) {
            throw new IllegalArgumentException("관리자 계정은 회원 탈퇴할 수 없습니다.");
        }
        if (user.isWithdrawn()) {
            throw new IllegalArgumentException("이미 탈퇴한 회원입니다.");
        }
        if (!passwordEncoder.matches(rawPassword, user.getPassword())) {
            throw new IllegalArgumentException("비밀번호가 일치하지 않습니다.");
        }
        user.withdraw();
    }
}
