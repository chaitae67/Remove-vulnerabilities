package com.example.clinic.controller;

import com.example.clinic.domain.AppUser;
import com.example.clinic.domain.Role;
import com.example.clinic.service.UserService;
import java.time.LocalDateTime;
import java.util.List;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.ResponseBody;

@Controller
public class AdminUserApiController {

    private final UserService userService;

    public AdminUserApiController(UserService userService) {
        this.userService = userService;
    }

    @GetMapping("/admin/users")
    public String usersPage(Model model) {
        List<AppUser> users = userService.findAllUsers();
        model.addAttribute("users", users);
        model.addAttribute("adminCount", users.stream().filter(user -> user.getRole() == Role.ADMIN).count());
        model.addAttribute("userCount", users.stream().filter(user -> user.getRole() == Role.USER).count());
        model.addAttribute("totalPointBalance", users.stream().mapToInt(AppUser::getPointBalance).sum());
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
