package com.example.clinic.controller;

import java.security.Principal;

import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import jakarta.servlet.http.HttpSession;
import java.time.Duration;
import java.time.Instant;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.ModelAttribute;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.servlet.mvc.support.RedirectAttributes;
import org.springframework.security.core.Authentication;
import org.springframework.security.web.authentication.logout.SecurityContextLogoutHandler;

import com.example.clinic.domain.AppUser;
import com.example.clinic.repository.AppUserRepository;
import com.example.clinic.repository.PaymentOrderRepository;
import com.example.clinic.repository.QnaPostRepository;
import com.example.clinic.repository.ReviewRepository;
import com.example.clinic.service.UserService;
import com.example.clinic.util.PrivacyMasker;

@Controller
public class MyPageController {

    private static final String PROFILE_REAUTH_AT = "PROFILE_REAUTH_AT";
    private static final Duration REAUTH_TTL = Duration.ofMinutes(5);

    private final AppUserRepository userRepository;
    private final PaymentOrderRepository paymentOrderRepository;
    private final QnaPostRepository qnaPostRepository;
    private final ReviewRepository reviewRepository;
    private final UserService userService;

    public MyPageController(AppUserRepository userRepository,
                             PaymentOrderRepository paymentOrderRepository,
                             QnaPostRepository qnaPostRepository,
                             ReviewRepository reviewRepository,
                             UserService userService) {
        this.userRepository = userRepository;
        this.paymentOrderRepository = paymentOrderRepository;
        this.qnaPostRepository = qnaPostRepository;
        this.reviewRepository = reviewRepository;
        this.userService = userService;
    }

    // IN-11: 조회/수정 대상 회원은 요청 파라미터(userId)가 아니라 인증된 세션에서 결정한다.
    @GetMapping("/mypage")
    public String myPage(Principal principal, Model model) {
        AppUser user = userService.findByUsername(principal.getName());
        model.addAttribute("user", user);
        model.addAttribute("maskedPhone", PrivacyMasker.phone(user.getPhone()));
        model.addAttribute("payments", paymentOrderRepository.findByBuyerOrderByCreatedAtDesc(user));
        model.addAttribute("qnaPosts", qnaPostRepository.findByWriterOrderByCreatedAtDesc(user));
        model.addAttribute("myReviews", reviewRepository.findByWriterOrderByCreatedAtDesc(user));
        return "mypage/index";
    }

    @GetMapping("/mypage/edit")
    public String editForm(Principal principal, HttpSession session, Model model) {
        if (!isRecentlyReauthenticated(session)) {
            return "mypage/reauth";
        }
        model.addAttribute("user", userService.findByUsername(principal.getName()));
        return "mypage/edit";
    }

    @PostMapping("/mypage/reauth")
    public String reauthenticate(@RequestParam String password,
                                 Principal principal,
                                 HttpSession session,
                                 RedirectAttributes redirectAttributes) {
        try {
            userService.verifyPassword(principal.getName(), password);
            session.setAttribute(PROFILE_REAUTH_AT, Instant.now());
            return "redirect:/mypage/edit";
        } catch (IllegalArgumentException exception) {
            redirectAttributes.addFlashAttribute("reauthError", "비밀번호를 다시 확인해 주세요.");
            return "redirect:/mypage/edit";
        }
    }

    @PostMapping("/mypage/edit")
    public String update(Principal principal,
                          @ModelAttribute AppUser form,
                          @RequestParam String currentPassword,
                          HttpSession session,
                          RedirectAttributes redirectAttributes) {
        if (!isRecentlyReauthenticated(session)) {
            redirectAttributes.addFlashAttribute("reauthError", "본인 확인 시간이 만료되었습니다.");
            return "redirect:/mypage/edit";
        }
        try {
            // 세션 재인증 이력과 별개로 저장 시점에 현재 비밀번호를 다시 확인한다.
            userService.updateProfile(principal.getName(), currentPassword, form);
            session.removeAttribute(PROFILE_REAUTH_AT);
            redirectAttributes.addFlashAttribute("message", "회원정보가 수정되었습니다.");
            return "redirect:/mypage";
        } catch (IllegalArgumentException exception) {
            redirectAttributes.addFlashAttribute("reauthError", exception.getMessage());
            return "redirect:/mypage/edit";
        }
    }

    @PostMapping("/mypage/withdraw")
    public String withdraw(@RequestParam String password,
                           Principal principal,
                           Authentication authentication,
                           HttpServletRequest request,
                           HttpServletResponse response,
                           RedirectAttributes redirectAttributes) {
        try {
            userService.withdraw(principal.getName(), password);
        } catch (IllegalArgumentException exception) {
            redirectAttributes.addFlashAttribute("withdrawError", exception.getMessage());
            return "redirect:/mypage";
        }

        new SecurityContextLogoutHandler().logout(request, response, authentication);
        redirectAttributes.addFlashAttribute("message", "회원 탈퇴가 완료되었습니다.");
        return "redirect:/";
    }

    private boolean isRecentlyReauthenticated(HttpSession session) {
        Object value = session.getAttribute(PROFILE_REAUTH_AT);
        if (!(value instanceof Instant verifiedAt)) return false;
        Duration age = Duration.between(verifiedAt, Instant.now());
        return !age.isNegative() && age.compareTo(REAUTH_TTL) <= 0;
    }
}
