package com.example.clinic.controller;

import com.example.clinic.service.UserService;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.servlet.mvc.support.RedirectAttributes;

@Controller
public class AuthController {

    private final UserService userService;

    public AuthController(UserService userService) {
        this.userService = userService;
    }

    @GetMapping("/login")
    public String login() {
        return "auth/login";
    }

    @GetMapping("/register")
    public String register() {
        return "auth/register";
    }

    @PostMapping("/register")
    public String createUser(
        @RequestParam String username,
        @RequestParam String password,
        @RequestParam String name,
        @RequestParam String email,
        @RequestParam(required = false) String phone,
        Model model,
        RedirectAttributes redirectAttributes
    ) {
        try {
            userService.register(username, password, name, email, phone);
            redirectAttributes.addFlashAttribute("message", "회원가입이 완료되었습니다. 로그인해 주세요.");
            return "redirect:/login";
        } catch (IllegalArgumentException ex) {
            model.addAttribute("error", ex.getMessage());
            return "auth/register";
        }
    }

    @GetMapping("/forgot-password")
    public String forgotPasswordForm() {
        return "auth/forgot-password";
    }

    @PostMapping("/forgot-password")
    public String forgotPassword(
        @RequestParam String username,
        @RequestParam String email,
        Model model
    ) {
        String token = userService.issuePasswordResetToken(username, email);
        if (token == null) {
            // VULNERABLE LAB: 계정이 없을 때와 있을 때 응답 메시지가 달라 계정 존재 여부를
            // 추측할 수 있다 (User Enumeration).
            model.addAttribute("error", "아이디와 이메일이 일치하는 계정을 찾을 수 없습니다.");
            return "auth/forgot-password";
        }
        // VULNERABLE LAB: 실제 서비스라면 이메일로만 전달해야 할 재설정 링크를 화면에 그대로 노출한다.
        model.addAttribute("message", "비밀번호 재설정 링크가 발급되었습니다.");
        model.addAttribute("resetLink", "/reset-password?token=" + token);
        return "auth/forgot-password";
    }

    @GetMapping("/reset-password")
    public String resetPasswordForm(@RequestParam String token, Model model) {
        model.addAttribute("token", token);
        return "auth/reset-password";
    }

    @PostMapping("/reset-password")
    public String resetPassword(
        @RequestParam String token,
        @RequestParam String newPassword,
        Model model,
        RedirectAttributes redirectAttributes
    ) {
        try {
            userService.resetPassword(token, newPassword);
            redirectAttributes.addFlashAttribute("message", "비밀번호가 변경되었습니다. 다시 로그인해 주세요.");
            return "redirect:/login";
        } catch (IllegalArgumentException ex) {
            model.addAttribute("error", ex.getMessage());
            model.addAttribute("token", token);
            return "auth/reset-password";
        }
    }
}
