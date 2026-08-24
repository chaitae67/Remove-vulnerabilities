package com.example.clinic.controller;

import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.ModelAttribute;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.servlet.mvc.support.RedirectAttributes;

import com.example.clinic.domain.AppUser;
import com.example.clinic.repository.AppUserRepository;
import com.example.clinic.repository.PaymentOrderRepository;
import com.example.clinic.repository.QnaPostRepository;
import com.example.clinic.service.UserService;

@Controller
public class MyPageController {

    private final AppUserRepository userRepository;
    private final PaymentOrderRepository paymentOrderRepository;
    private final QnaPostRepository qnaPostRepository;
    private final UserService userService;

    public MyPageController(AppUserRepository userRepository,
                             PaymentOrderRepository paymentOrderRepository,
                             QnaPostRepository qnaPostRepository,
                             UserService userService) {
        this.userRepository = userRepository;
        this.paymentOrderRepository = paymentOrderRepository;
        this.qnaPostRepository = qnaPostRepository;
        this.userService = userService;
    }

    @GetMapping("/mypage")
    public String myPage(@RequestParam Long userId, Model model) {
        var user = userRepository.findById(userId).orElseThrow();
        model.addAttribute("user", user);
        model.addAttribute("payments", paymentOrderRepository.findByBuyerOrderByCreatedAtDesc(user));
        model.addAttribute("qnaPosts", qnaPostRepository.findByWriterOrderByCreatedAtDesc(user));
        return "mypage/index";
    }

    @GetMapping("/mypage/edit")
    public String editForm(@RequestParam Long userId, Model model) {
        model.addAttribute("user", userService.findById(userId));
        return "mypage/edit";
    }

    @PostMapping("/mypage/edit")
    public String update(@RequestParam Long userId,
                          @ModelAttribute AppUser form,
                          RedirectAttributes redirectAttributes) {
        userService.updateProfile(userId, form);
        redirectAttributes.addFlashAttribute("message", "회원정보가 수정되었습니다.");
        return "redirect:/mypage?userId=" + userId;
    }
}