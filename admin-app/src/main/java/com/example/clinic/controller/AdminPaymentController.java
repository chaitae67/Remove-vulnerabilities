package com.example.clinic.controller;

import com.example.clinic.service.PaymentService;
import java.math.BigDecimal;
import java.time.LocalDate;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.servlet.mvc.support.RedirectAttributes;

@Controller
public class AdminPaymentController {

    private final PaymentService paymentService;

    public AdminPaymentController(PaymentService paymentService) {
        this.paymentService = paymentService;
    }

    @GetMapping("/admin/payments")
    public String list(Model model) {
        model.addAttribute("orders", paymentService.findAllOrders());
        return "admin/payments";
    }

    @GetMapping("/admin/payments/{id}")
    public String detail(@PathVariable Long id, Model model) {
        model.addAttribute("order", paymentService.findById(id));
        return "admin/payment-detail";
    }

    @PostMapping("/admin/payments/{id}")
    public String update(
        @PathVariable Long id,
        @RequestParam BigDecimal amount,
        @RequestParam(required = false) String method,
        @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate reservationDate,
        RedirectAttributes redirectAttributes
    ) {
        try {
            paymentService.updateOrder(id, amount, method, reservationDate);
            redirectAttributes.addFlashAttribute("message", "결제 내역이 수정되었습니다.");
        } catch (IllegalArgumentException e) {
            redirectAttributes.addFlashAttribute("error", e.getMessage());
        }
        return "redirect:/admin/payments/" + id;
    }

    @PostMapping("/admin/payments/{id}/refund")
    public String refund(@PathVariable Long id, RedirectAttributes redirectAttributes) {
        try {
            paymentService.refund(id);
            redirectAttributes.addFlashAttribute("message", "환불 처리되었습니다. 사용 포인트는 반환하고 적립 포인트는 회수했습니다.");
        } catch (IllegalArgumentException e) {
            redirectAttributes.addFlashAttribute("error", e.getMessage());
        }
        return "redirect:/admin/payments/" + id;
    }
}
