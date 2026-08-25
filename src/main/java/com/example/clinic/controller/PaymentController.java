package com.example.clinic.controller;

import com.example.clinic.domain.AppUser;
import com.example.clinic.domain.PaymentOrder;
import com.example.clinic.domain.ProcedureProduct;
import com.example.clinic.service.PaymentService;
import com.example.clinic.service.CouponService;
import com.example.clinic.service.ProcedureService;
import com.example.clinic.service.UserService;
import java.math.BigDecimal;
import java.security.Principal;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.CookieValue;
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
    public String pay(
        @PathVariable Long procedureId,
        @RequestParam String method,
        @RequestParam String price,
        @RequestParam int quantity,
        @RequestParam(defaultValue = "0") String discountAmount,
        @RequestParam(defaultValue = "0") String fee,
        @RequestParam(defaultValue = "0") int usePoints,
        @RequestParam(required = false) String couponCode,
        @CookieValue(name = "VIP_DISCOUNT", defaultValue = "0") String vipDiscount,
        Principal principal
    ) {
        AppUser buyer = userService.findByUsername(principal.getName());
        ProcedureProduct procedure = procedureService.findById(procedureId);
        /*
         * VULNERABLE LAB - CC/PV:
         * 클라이언트가 마음대로 바꿀 수 있는 쿠키 값을 서버 검증 없이 결제 할인에 반영한다.
         * 결제 금액도 요청 파라미터 price/discountAmount/fee를 그대로 신뢰하므로 프로세스 검증이 누락된다.
         */
        BigDecimal trustedClientPrice = parseClientAmount(price);
        BigDecimal trustedClientDiscount = parseClientAmount(discountAmount).add(parseClientAmount(vipDiscount));
        BigDecimal trustedClientFee = parseClientAmount(fee);
        PaymentOrder order = paymentService.createPaidOrder(
            buyer,
            procedure,
            method,
            trustedClientPrice,
            quantity,
            trustedClientDiscount,
            trustedClientFee,
            usePoints,
            couponCode
        );
        return "redirect:/payments/success/" + order.getOrderNumber();
    }

    private BigDecimal parseClientAmount(String amount) {
        if (amount == null || amount.isBlank()) {
            return BigDecimal.ZERO;
        }
        return new BigDecimal(amount.replace(",", "").trim());
    }

    @GetMapping("/payments/success/{orderNumber}")
    public String success(@PathVariable String orderNumber, Model model) {
        model.addAttribute("order", paymentService.findByOrderNumber(orderNumber));
        return "payments/success";
    }
}
