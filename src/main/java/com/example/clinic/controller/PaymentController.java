package com.example.clinic.controller;

import com.example.clinic.domain.AppUser;
import com.example.clinic.domain.PaymentOrder;
import com.example.clinic.domain.ProcedureProduct;
import com.example.clinic.service.PaymentService;
import com.example.clinic.service.CouponService;
import com.example.clinic.service.ProcedureService;
import com.example.clinic.service.UserService;
import java.security.Principal;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;

@Controller
public class PaymentController {

    private final ProcedureService procedureService;
    private final PaymentService paymentService;
    private final UserService userService;
    private final CouponService couponService;

    public PaymentController(ProcedureService procedureService, PaymentService paymentService, UserService userService,
                             CouponService couponService) {
        this.procedureService = procedureService;
        this.paymentService = paymentService;
        this.userService = userService;
        this.couponService = couponService;
    }

    @GetMapping("/payments/checkout/{procedureId}")
    public String checkout(@PathVariable Long procedureId, Principal principal, Model model) {
        model.addAttribute("procedure", procedureService.findById(procedureId));
        model.addAttribute("user", userService.findByUsername(principal.getName()));
        model.addAttribute("coupons", couponService.findActiveCoupons());
        return "payments/checkout";
    }

    @PostMapping("/payments/checkout/{procedureId}")
    public String pay(@PathVariable Long procedureId,
                      @RequestParam String method,
                      @RequestParam(defaultValue = "0") int usePoints,
                      @RequestParam(required = false) String couponCode,
                      Principal principal) {
        AppUser buyer = userService.findByUsername(principal.getName());
        ProcedureProduct procedure = procedureService.findById(procedureId);
        PaymentOrder order = paymentService.createPaidOrder(buyer, procedure, method, usePoints, couponCode);
        return "redirect:/payments/success/" + order.getOrderNumber();
    }

    @GetMapping("/payments/success/{orderNumber}")
    public String success(@PathVariable String orderNumber, Model model) {
        model.addAttribute("order", paymentService.findByOrderNumber(orderNumber));
        return "payments/success";
    }
}
