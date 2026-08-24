package com.example.clinic.controller;

import com.example.clinic.repository.AppUserRepository;
import com.example.clinic.repository.PaymentOrderRepository;
import com.example.clinic.repository.QnaPostRepository;
import com.example.clinic.service.UserService;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.security.core.Authentication;
import org.springframework.security.web.authentication.logout.SecurityContextLogoutHandler;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.servlet.mvc.support.RedirectAttributes;

@Controller
public class MyPageController {

    private final AppUserRepository userRepository;
    private final PaymentOrderRepository paymentOrderRepository;
    private final QnaPostRepository qnaPostRepository;
    private final UserService userService;

    public MyPageController(
            AppUserRepository userRepository,
            PaymentOrderRepository paymentOrderRepository,
            QnaPostRepository qnaPostRepository,
            UserService userService
    ) {
        this.userRepository = userRepository;
        this.paymentOrderRepository = paymentOrderRepository;
        this.qnaPostRepository = qnaPostRepository;
        this.userService = userService;
    }

    @GetMapping("/mypage")
    public String myPage(Authentication authentication, Model model) {
        var user = userRepository.findByUsername(authentication.getName())
                .orElseThrow();

        model.addAttribute("user", user);
        model.addAttribute("payments",
                paymentOrderRepository.findByBuyerOrderByCreatedAtDesc(user));
        model.addAttribute("qnaPosts",
                qnaPostRepository.findByWriterOrderByCreatedAtDesc(user));

        return "mypage/index";
    }

    @PostMapping("/mypage/withdraw")
public String withdraw(@RequestParam Long userId) {
    userRepository.deleteById(userId);
    return "redirect:/";
}
}