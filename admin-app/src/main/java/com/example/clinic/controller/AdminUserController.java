package com.example.clinic.controller;

import com.example.clinic.domain.AppUser;
import com.example.clinic.domain.Role;
import com.example.clinic.service.PaymentService;
import com.example.clinic.service.UserService;
import java.security.Principal;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.servlet.mvc.support.RedirectAttributes;

@Controller
public class AdminUserController {

    private final UserService userService;
    private final PaymentService paymentService;

    public AdminUserController(UserService userService, PaymentService paymentService) {
        this.userService = userService;
        this.paymentService = paymentService;
    }

    @GetMapping("/admin/users/{id}")
    public String detail(@PathVariable Long id, Model model) {
        AppUser user = userService.findById(id);
        model.addAttribute("user", user);
        model.addAttribute("orders", paymentService.findOrdersByBuyer(user));
        return "admin/user-detail";
    }

    @PostMapping("/admin/users/{id}")
    public String update(
        @PathVariable Long id,
        @RequestParam String name,
        @RequestParam String email,
        @RequestParam(required = false) String phone,
        @RequestParam(defaultValue = "0") int pointBalance,
        RedirectAttributes redirectAttributes
    ) {
        try {
            userService.updateByAdmin(id, name, email, phone, pointBalance);
            redirectAttributes.addFlashAttribute("message", "회원 정보가 수정되었습니다.");
        } catch (IllegalArgumentException e) {
            redirectAttributes.addFlashAttribute("error", e.getMessage());
        }
        return "redirect:/admin/users/" + id;
    }

    @PostMapping("/admin/users/{id}/role")
    public String changeRole(
        @PathVariable Long id,
        @RequestParam Role role,
        Principal principal,
        RedirectAttributes redirectAttributes
    ) {
        try {
            userService.changeRole(id, role, principal == null ? null : principal.getName());
            redirectAttributes.addFlashAttribute(
                "message",
                role == Role.ADMIN ? "관리자 권한을 부여했습니다." : "관리자 권한을 회수했습니다."
            );
        } catch (IllegalArgumentException e) {
            redirectAttributes.addFlashAttribute("error", e.getMessage());
        }
        return "redirect:/admin/users/" + id;
    }
}
