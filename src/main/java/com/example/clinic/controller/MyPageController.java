package com.example.clinic.controller;

import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;

import com.example.clinic.repository.AppUserRepository;
import com.example.clinic.repository.PaymentOrderRepository;
import com.example.clinic.repository.QnaPostRepository;
import com.example.clinic.repository.UserCouponRepository;
import com.example.clinic.service.PointService;

@Controller
public class MyPageController {

    private final AppUserRepository userRepository;
    private final PaymentOrderRepository paymentOrderRepository;
    private final QnaPostRepository qnaPostRepository;
    private final UserCouponRepository userCouponRepository;
    private final PointService pointService;

    public MyPageController(AppUserRepository userRepository,
                             PaymentOrderRepository paymentOrderRepository,
                             QnaPostRepository qnaPostRepository,
                             UserCouponRepository userCouponRepository,
                             PointService pointService) {
        this.userRepository = userRepository;
        this.paymentOrderRepository = paymentOrderRepository;
        this.qnaPostRepository = qnaPostRepository;
        this.userCouponRepository = userCouponRepository;
        this.pointService = pointService;
    }

    @GetMapping("/mypage")
    public String myPage(@RequestParam Long userId, Model model) {
        var user = userRepository.findById(userId).orElseThrow();
        model.addAttribute("user", user);
        model.addAttribute("payments", paymentOrderRepository.findByBuyerOrderByCreatedAtDesc(user));
        model.addAttribute("qnaPosts", qnaPostRepository.findByWriterOrderByCreatedAtDesc(user));
        model.addAttribute("pointBalance", pointService.getBalance(user));
        model.addAttribute("pointHistory", pointService.findHistory(user));
        model.addAttribute("myCoupons", userCouponRepository.findByUserOrderByIssuedAtDesc(user));
        return "mypage/index";
    }
}
