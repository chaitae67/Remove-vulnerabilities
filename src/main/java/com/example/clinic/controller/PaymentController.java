package com.example.clinic.controller;

import com.example.clinic.domain.AppUser;
import com.example.clinic.domain.PaymentOrder;
import com.example.clinic.domain.ProcedureProduct;
import com.example.clinic.service.PaymentService;
import com.example.clinic.service.ProcedureService;
import com.example.clinic.service.UserService;
import java.security.Principal;
import java.time.LocalDate;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.servlet.mvc.support.RedirectAttributes;
import org.springframework.format.annotation.DateTimeFormat;

@Controller
public class PaymentController {

    private final ProcedureService procedureService;
    private final PaymentService paymentService;
    private final UserService userService;

    public PaymentController(ProcedureService procedureService, PaymentService paymentService, UserService userService) {
        this.procedureService = procedureService;
        this.paymentService = paymentService;
        this.userService = userService;
    }

    @GetMapping("/payments/checkout/{procedureId}")
    public String checkout(@PathVariable Long procedureId, Principal principal, Model model) {
        AppUser user = userService.findByUsername(principal.getName());
        model.addAttribute("procedure", procedureService.findById(procedureId));
        model.addAttribute("user", user);
        model.addAttribute("coupons", paymentService.findAvailableCoupons(user));
        model.addAttribute("minReservationDate", LocalDate.now().toString());
        return "payments/checkout";
    }

    @PostMapping("/payments/checkout/{procedureId}")
    public String pay(
        @PathVariable Long procedureId,
        @RequestParam String method,
        @RequestParam int quantity,
        @RequestParam(defaultValue = "0") int usePoints,
        @RequestParam(required = false) String couponCode,
        @RequestParam @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate reservationDate,
        Principal principal,
        RedirectAttributes redirectAttributes
    ) {
        AppUser buyer = userService.findByUsername(principal.getName());
        ProcedureProduct procedure = procedureService.findById(procedureId);
        try {
            PaymentOrder order = paymentService.createPaidOrder(buyer, procedure, method, quantity, usePoints, couponCode, reservationDate);
            return "redirect:/payments/success/" + order.getOrderNumber();
        } catch (IllegalArgumentException ex) {
            redirectAttributes.addFlashAttribute("error", ex.getMessage());
            return "redirect:/payments/checkout/" + procedureId;
        }
    }

    @GetMapping("/payments/success/{orderNumber}")
    public String success(@PathVariable String orderNumber, Principal principal, Model model) {
        AppUser buyer = userService.findByUsername(principal.getName());
        model.addAttribute("order", paymentService.findByOrderNumberAndBuyer(orderNumber, buyer));
        return "payments/success";
    }

    @GetMapping("/payments/{orderNumber}")
    public String detail(@PathVariable String orderNumber, Principal principal, Model model) {
        AppUser buyer = userService.findByUsername(principal.getName());
        model.addAttribute("order", paymentService.findByOrderNumberAndBuyer(orderNumber, buyer));
        return "payments/detail";
    }
}
