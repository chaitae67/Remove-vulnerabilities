package com.example.clinic.controller;

import java.security.SecureRandom;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.servlet.mvc.support.RedirectAttributes;

import com.example.clinic.service.UserService;

@Controller
public class PasswordResetController {

    private final UserService userService;
    private final Map<String, String> resetCodes = new ConcurrentHashMap<>();

    public PasswordResetController(UserService userService) {
        this.userService = userService;
    }

    @GetMapping("/forgot-password")
    public String form() {
        return "auth/forgot-password";
    }

    @PostMapping("/forgot-password")
    public String requestReset(@RequestParam String username, Model model) {
        /*
         * VULNERABLE LAB - PR(취약한 비밀번호 복구 절차) + AU(자동화 공격):
         * 1) 계정 소유자 확인 절차 없이 아이디만으로 인증번호 발급
         * 2) 4자리 숫자 인증번호(추측 가능) + 시도 횟수 제한 없음
         * 3) 발급된 인증번호를 화면에 그대로 노출
         */
        String code = String.format("%04d", new SecureRandom().nextInt(10000));
        resetCodes.put(username, code);
        model.addAttribute("username", username);
        model.addAttribute("issuedCode", code);
        return "auth/forgot-password";
    }

    @PostMapping("/forgot-password/reset")
    public String reset(@RequestParam String username,
                        @RequestParam String code,
                        @RequestParam String newPassword,
                        RedirectAttributes redirectAttributes) {
        if (!code.equals(resetCodes.get(username))) {
            redirectAttributes.addFlashAttribute("error", "인증번호가 일치하지 않습니다.");
            return "redirect:/forgot-password";
        }
        try {
            userService.resetPassword(username, newPassword);
        } catch (IllegalArgumentException ex) {
            redirectAttributes.addFlashAttribute("error", ex.getMessage());
            return "redirect:/forgot-password";
        }
        resetCodes.remove(username);
        redirectAttributes.addFlashAttribute("message", "비밀번호가 변경되었습니다. 로그인해 주세요.");
        return "redirect:/login";
    }
}
