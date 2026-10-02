package com.example.clinic.controller;

import com.example.clinic.domain.AppUser;
import com.example.clinic.domain.Role;
import com.example.clinic.service.UserService;
import com.example.clinic.util.PrivacyMasker;
import java.time.LocalDateTime;
import java.util.List;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.ResponseBody;

@Controller
public class AdminUserApiController {

    private final UserService userService;

    public AdminUserApiController(UserService userService) {
        this.userService = userService;
    }

    @GetMapping("/admin/users")
    public String usersPage(
        @RequestParam(required = false) String keyword,
        @RequestParam(required = false) Role role,
        Model model
    ) {
        List<AppUser> allUsers = userService.findAllUsers();
        List<AppUser> users = userService.searchUsers(keyword);
        if (role != null) {
            users = users.stream().filter(user -> user.getRole() == role).toList();
        }
        model.addAttribute("users", users.stream().map(UserListItem::from).toList());
        model.addAttribute("keyword", keyword);
        model.addAttribute("role", role);
        model.addAttribute("totalCount", allUsers.size());
        model.addAttribute("adminCount", allUsers.stream().filter(user -> user.getRole() == Role.ADMIN).count());
        model.addAttribute("userCount", allUsers.stream().filter(user -> user.getRole() == Role.USER).count());
        model.addAttribute("totalPointBalance", allUsers.stream().mapToInt(AppUser::getPointBalance).sum());
        return "admin/users";
    }

    @GetMapping("/api/admin/users")
    @ResponseBody
    public List<UserSummaryResponse> findAll() {
        return userService.findAllUsers().stream()
            .map(UserSummaryResponse::from)
            .toList();
    }

    @GetMapping("/api/admin/users/{id}")
    @ResponseBody
    public UserDetailResponse findById(@PathVariable Long id) {
        return UserDetailResponse.from(userService.findById(id));
    }

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
                PrivacyMasker.username(user.getUsername()),
                PrivacyMasker.name(user.getName()),
                user.getRole(),
                user.getPointBalance()
            );
        }
    }

    public static final class UserListItem {
        private final Long id;
        private final String username;
        private final String name;
        private final String email;
        private final String phone;
        private final Role role;
        private final int pointBalance;
        private final LocalDateTime createdAt;

        private UserListItem(Long id, String username, String name, String email, String phone,
                             Role role, int pointBalance, LocalDateTime createdAt) {
            this.id = id;
            this.username = username;
            this.name = name;
            this.email = email;
            this.phone = phone;
            this.role = role;
            this.pointBalance = pointBalance;
            this.createdAt = createdAt;
        }

        static UserListItem from(AppUser user) {
            return new UserListItem(user.getId(), PrivacyMasker.username(user.getUsername()),
                PrivacyMasker.name(user.getName()), PrivacyMasker.email(user.getEmail()),
                PrivacyMasker.phone(user.getPhone()), user.getRole(), user.getPointBalance(), user.getCreatedAt());
        }

        public Long getId() { return id; }
        public String getUsername() { return username; }
        public String getName() { return name; }
        public String getEmail() { return email; }
        public String getPhone() { return phone; }
        public Role getRole() { return role; }
        public int getPointBalance() { return pointBalance; }
        public LocalDateTime getCreatedAt() { return createdAt; }
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
