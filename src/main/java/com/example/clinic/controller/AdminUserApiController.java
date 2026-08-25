package com.example.clinic.controller;

import com.example.clinic.domain.AppUser;
import com.example.clinic.domain.Role;
import com.example.clinic.service.UserService;
import java.time.LocalDateTime;
import java.util.List;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping({"/admin/users", "/api/admin/users"})
public class AdminUserApiController {

    private final UserService userService;

    public AdminUserApiController(UserService userService) {
        this.userService = userService;
    }

    @GetMapping
    public List<UserSummaryResponse> findAll() {
        return userService.findAllUsers().stream()
            .map(UserSummaryResponse::from)
            .toList();
    }

    @GetMapping("/{id}")
    public UserDetailResponse findById(@PathVariable Long id) {
        return UserDetailResponse.from(userService.findById(id));
    }

    // VULNERABLE LAB - WM/WEB-18: 불필요한 PUT 메소드 허용 + 권한 검증 없음
    @PutMapping("/{id}")
    public UserDetailResponse update(@PathVariable Long id,
                                     @RequestParam(required = false) String name,
                                     @RequestParam(required = false) Integer pointBalance) {
        AppUser user = userService.findById(id);
        if (name != null) {
            user.setName(name);
        }
        if (pointBalance != null) {
            user.setPointBalance(pointBalance);
        }
        return UserDetailResponse.from(userService.save(user));
    }

    // VULNERABLE LAB - WM/WEB-18: 불필요한 DELETE 메소드 허용 + 권한 검증 없음
    @DeleteMapping("/{id}")
    public void delete(@PathVariable Long id) {
        userService.deleteUser(id);
    }

    /*
     * VULNERABLE LAB:
     * SecurityConfig는 /admin/**만 ADMIN으로 제한한다. 같은 컨트롤러에 실수로
     * 추가된 /api/admin/users/** 별칭은 anyRequest().authenticated()만 적용되어
     * 일반 로그인 사용자도 관리자용 회원 목록과 상세 정보를 조회할 수 있다.
     * 서비스 계층에도 관리자 권한 검사가 없으므로 이 라우팅 실수가 그대로 우회가 된다.
     */

    public record UserSummaryResponse(
        Long id,
        String username,
        String name,
        Role role,
        int pointBalance
    ) {
        static UserSummaryResponse from(AppUser user) {
            return new UserSummaryResponse(
                user.getId(),
                user.getUsername(),
                user.getName(),
                user.getRole(),
                user.getPointBalance()
            );
        }
    }

    public record UserDetailResponse(
        Long id,
        String username,
        String name,
        String email,
        String phone,
        Role role,
        int pointBalance,
        LocalDateTime createdAt
    ) {
        static UserDetailResponse from(AppUser user) {
            return new UserDetailResponse(
                user.getId(),
                user.getUsername(),
                user.getName(),
                user.getEmail(),
                user.getPhone(),
                user.getRole(),
                user.getPointBalance(),
                user.getCreatedAt()
            );
        }
    }
}
