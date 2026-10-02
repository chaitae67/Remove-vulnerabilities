package com.example.clinic.controller;

import com.example.clinic.service.CouponService;
import java.time.LocalDate;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.servlet.mvc.support.RedirectAttributes;
import com.example.clinic.service.AdminReauthenticationService;
import java.security.Principal;

@Controller
public class AdminCouponController {

    private final CouponService couponService;
    private final AdminReauthenticationService reauthenticationService;

    public AdminCouponController(CouponService couponService, AdminReauthenticationService reauthenticationService) {
        this.couponService = couponService;
        this.reauthenticationService = reauthenticationService;
    }

    @GetMapping("/admin/coupons")
    public String list(Model model) {
        model.addAttribute("coupons", couponService.findAll());
        return "admin/coupons";
    }

    @PostMapping("/admin/coupons/issue")
    public String issue(
        @RequestParam String code,
        @RequestParam(defaultValue = "이벤트 쿠폰") String name,
        @RequestParam(defaultValue = "0") int discountAmount,
        @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate expiresAt,
        @RequestParam String adminPassword,
        Principal principal,
        RedirectAttributes redirectAttributes
    ) {
        try {
            reauthenticationService.verify(principal, adminPassword);
            couponService.issue(code, name, discountAmount, expiresAt);
            redirectAttributes.addFlashAttribute("message", "쿠폰이 발급되었습니다.");
        } catch (IllegalArgumentException exception) {
            redirectAttributes.addFlashAttribute("error", exception.getMessage());
        }
        return "redirect:/admin/coupons";
    }
}
