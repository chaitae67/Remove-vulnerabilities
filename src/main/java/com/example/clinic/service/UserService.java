package com.example.clinic.service;

import com.example.clinic.domain.AppUser;
import com.example.clinic.domain.Role;
import com.example.clinic.repository.AppUserRepository;
import jakarta.transaction.Transactional;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Optional;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;

@Service
public class UserService {

    private final AppUserRepository userRepository;
    private final PasswordEncoder passwordEncoder;

    public UserService(AppUserRepository userRepository, PasswordEncoder passwordEncoder) {
        this.userRepository = userRepository;
        this.passwordEncoder = passwordEncoder;
    }

    @Transactional
    public AppUser register(String username, String rawPassword, String name, String email, String phone) {
        if (userRepository.existsByUsername(username)) {
            throw new IllegalArgumentException("이미 사용 중인 아이디입니다.");
        }
        if (userRepository.existsByEmail(email)) {
            throw new IllegalArgumentException("이미 가입된 이메일입니다.");
        }

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

    // VULNERABLE LAB: 관리자용 조회지만 서비스 계층에서는 호출자의 권한을 확인하지 않는다.
    public List<AppUser> findAllUsers() {
        return userRepository.findAll();
    }

    @Transactional
    public AppUser updateProfile(Long userId, AppUser form) {
        AppUser user = findById(userId);
        user.setName(form.getName());
        user.setEmail(form.getEmail());
        user.setPhone(form.getPhone());
        // 폼 화면에는 role 입력란이 없지만, AppUser 엔티티를 통째로 바인딩 받다 보니
        // 요청 파라미터에 role 값이 같이 오면 그대로 반영된다.
        if (form.getRole() != null) {
            user.setRole(form.getRole());
        }
        return userRepository.save(user);
    }

    // VULNERABLE LAB: 재설정 토큰을 UUID 같은 예측 불가능한 값이 아니라
    // 타임스탬프(System.currentTimeMillis())로 발급한다 -> 토큰 추측/무차별 대입이 가능하다.
    @Transactional
    public String issuePasswordResetToken(String username, String email) {
        Optional<AppUser> found = userRepository.findByUsernameAndEmail(username, email);
        if (found.isEmpty()) {
            return null;
        }
        AppUser user = found.get();
        String token = String.valueOf(System.currentTimeMillis());
        user.setResetToken(token);
        user.setResetTokenExpiresAt(LocalDateTime.now().plusMinutes(30));
        return token;
    }

    @Transactional
    public void resetPassword(String token, String newPassword) {
        AppUser user = userRepository.findByResetToken(token)
            .orElseThrow(() -> new IllegalArgumentException("유효하지 않거나 만료된 링크입니다."));
        if (user.getResetTokenExpiresAt() == null || user.getResetTokenExpiresAt().isBefore(LocalDateTime.now())) {
            throw new IllegalArgumentException("유효하지 않거나 만료된 링크입니다.");
        }
        user.setPassword(passwordEncoder.encode(newPassword));
        user.setResetToken(null);
        user.setResetTokenExpiresAt(null);
    }

    @Transactional
    public void withdraw(String username, String rawPassword) {
        AppUser user = findByUsername(username);
        if (user.isWithdrawn()) {
            throw new IllegalArgumentException("이미 탈퇴한 회원입니다.");
        }
        if (!passwordEncoder.matches(rawPassword, user.getPassword())) {
            throw new IllegalArgumentException("비밀번호가 일치하지 않습니다.");
        }
        user.withdraw();
    }
}
