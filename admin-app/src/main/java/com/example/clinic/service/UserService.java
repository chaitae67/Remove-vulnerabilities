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

    public List<AppUser> findAllUsers() {
        return userRepository.findAll();
    }

    /**
     * 아이디 / 이름 / 이메일 / 연락처 중 하나라도 키워드를 포함하는 회원을 찾는다.
     */
    public List<AppUser> searchUsers(String keyword) {
        if (keyword == null || keyword.isBlank()) {
            return findAllUsers();
        }
        return userRepository.searchByKeywordPattern(toLikePattern(keyword.trim()));
    }

    /**
     * 검색어를 소문자 {@code %키워드%} LIKE 패턴으로 바꾼다.
     * 사용자가 입력한 '%', '_' 는 와일드카드가 아닌 글자로 취급하도록 '!' 로 이스케이프한다.
     */
    private String toLikePattern(String keyword) {
        String escaped = keyword.toLowerCase()
            .replace("!", "!!")
            .replace("%", "!%")
            .replace("_", "!_");
        return "%" + escaped + "%";
    }

    /**
     * 관리자 화면에서 회원 정보를 수정한다.
     * 권한(role)은 별도의 {@link #changeRole} 로만 바꿀 수 있도록 분리해 두었다.
     */
    @Transactional
    public AppUser updateByAdmin(Long id, String name, String email, String phone, int pointBalance) {
        AppUser user = findById(id);
        if (name == null || name.isBlank()) {
            throw new IllegalArgumentException("이름을 입력해 주세요.");
        }
        if (email == null || email.isBlank()) {
            throw new IllegalArgumentException("이메일을 입력해 주세요.");
        }
        if (pointBalance < 0) {
            throw new IllegalArgumentException("포인트는 0 이상이어야 합니다.");
        }
        userRepository.findByEmail(email.trim())
            .filter(other -> !other.getId().equals(user.getId()))
            .ifPresent(other -> {
                throw new IllegalArgumentException("이미 다른 회원이 사용 중인 이메일입니다.");
            });

        user.setName(name.trim());
        user.setEmail(email.trim());
        user.setPhone(phone == null || phone.isBlank() ? null : phone.trim());
        user.setPointBalance(pointBalance);
        return userRepository.save(user);
    }

    /**
     * 직원 계정에 관리자 권한을 부여하거나 회수한다.
     * 잠금 상태를 막기 위해 본인 계정의 관리자 권한은 스스로 내릴 수 없다.
     */
    @Transactional
    public AppUser changeRole(Long id, Role role, String actingUsername) {
        AppUser user = findById(id);
        if (role == null) {
            throw new IllegalArgumentException("변경할 권한을 선택해 주세요.");
        }
        if (role == Role.USER && user.getUsername().equals(actingUsername)) {
            throw new IllegalArgumentException("본인 계정의 관리자 권한은 회수할 수 없습니다.");
        }
        if (user.isWithdrawn() && role == Role.ADMIN) {
            throw new IllegalArgumentException("탈퇴한 회원에게는 관리자 권한을 부여할 수 없습니다.");
        }
        user.setRole(role);
        return userRepository.save(user);
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
