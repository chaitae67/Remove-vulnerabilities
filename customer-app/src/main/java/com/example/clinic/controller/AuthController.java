package com.example.clinic.controller;

import com.example.clinic.service.EmailService;
import com.example.clinic.service.UserService;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.servlet.mvc.support.RedirectAttributes;

@Controller
public class AuthController {

    private final UserService userService;
    private final EmailService emailService;
    private final String baseUrl;

    public AuthController(
        UserService userService,
        EmailService emailService,
        @Value("${app.base-url}") String baseUrl
    ) {
        this.userService = userService;
        this.emailService = emailService;
        this.baseUrl = baseUrl;
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
        // PR-12: 비밀번호 자체를 전송하지 않고 일회용·30분 만료 토큰 링크만 발송한다.
        // 계정 존재 여부와 메일 발송 성공 여부는 동일한 응답으로 감춘다.
        String token = userService.issuePasswordResetToken(username, email);
        if (token != null) {
            try {
                emailService.send(email, "[제로데이클리닉] 비밀번호 재설정 안내",
                    "아래 링크는 30분 동안 한 번만 사용할 수 있습니다.\n"
                    + baseUrl + "/reset-password?token="
                    + java.net.URLEncoder.encode(token, java.nio.charset.StandardCharsets.UTF_8));
            } catch (Exception ignored) {
                // 메일 발송 실패 여부도 응답으로 노출하지 않는다.
            }
        }
        model.addAttribute("message",
            "입력하신 정보와 일치하는 계정이 있다면 등록된 이메일로 재설정 링크를 발송했습니다.");
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
