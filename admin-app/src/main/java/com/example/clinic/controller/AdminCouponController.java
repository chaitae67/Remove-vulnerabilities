package com.example.clinic.controller;

import com.example.clinic.service.CouponService;
import java.time.LocalDate;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.servlet.mvc.support.RedirectAttributes;

@Controller
public class AdminCouponController {

    private final CouponService couponService;

    public AdminCouponController(CouponService couponService) {
        this.couponService = couponService;
    }

    @GetMapping("/admin/coupons")
    public String list(Model model) {
        model.addAttribute("coupons", couponService.findAll());
        return "admin/coupons";
    }

    /**
     * 이벤트 쿠폰 발급. (실습용) 상태를 바꾸는 요청을 GET + CSRF 토큰 없이 처리한다.
     * 관리자 앱은 SecurityConfig 에서 csrf().disable() 상태라, 피해자 관리자가 로그인한
     * 브라우저로 이 URL 을 열게만 만들면(이미지/링크 등) 임의 쿠폰이 발급된다(CSRF).
     */
    @GetMapping("/admin/coupons/issue")
    public String issue(
        @RequestParam String code,
        @RequestParam(defaultValue = "이벤트 쿠폰") String name,
        @RequestParam(defaultValue = "0") int discountAmount,
        @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate expiresAt,
        RedirectAttributes redirectAttributes
    ) {
        couponService.issue(code, name, discountAmount, expiresAt);
        redirectAttributes.addFlashAttribute("message", "쿠폰이 발급되었습니다: " + code);
        return "redirect:/admin/coupons";
    }
}
