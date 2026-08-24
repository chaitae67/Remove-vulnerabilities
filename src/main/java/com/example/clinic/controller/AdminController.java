package com.example.clinic.controller;

import com.example.clinic.service.PaymentService;
import com.example.clinic.service.QnaService;
import com.example.clinic.service.QuickConsultationService;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;

@Controller
public class AdminController {

    private final QuickConsultationService consultationService;
    private final PaymentService paymentService;
    private final QnaService qnaService;

    public AdminController(QuickConsultationService consultationService, PaymentService paymentService, QnaService qnaService) {
        this.consultationService = consultationService;
        this.paymentService = paymentService;
        this.qnaService = qnaService;
    }

    @GetMapping("/admin")
    public String dashboard(Model model) {
        model.addAttribute("consultations", consultationService.findRecentConsultations());
        model.addAttribute("orders", paymentService.findRecentOrders());
        model.addAttribute("qnas", qnaService.findAll());
        return "admin/dashboard";
    }
}
