package com.example.clinic.controller;

import com.example.clinic.service.PaymentService;
import com.example.clinic.service.AdminReauthenticationService;
import com.example.clinic.domain.PaymentOrder;
import com.example.clinic.domain.PaymentStatus;
import com.example.clinic.util.PrivacyMasker;
import java.security.Principal;
import java.math.BigDecimal;
import java.time.LocalDateTime;
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
    private final AdminReauthenticationService reauthenticationService;

    public AdminPaymentController(PaymentService paymentService, AdminReauthenticationService reauthenticationService) {
        this.paymentService = paymentService;
        this.reauthenticationService = reauthenticationService;
    }

    @GetMapping("/admin/payments")
    public String list(Model model) {
        model.addAttribute("orders", paymentService.findAllOrders().stream().map(PaymentListItem::from).toList());
        return "admin/payments";
    }

    public static final class PaymentListItem {
        private final Long id;
        private final String orderNumber;
        private final Long buyerId;
        private final String buyerName;
        private final String procedureName;
        private final BigDecimal amount;
        private final PaymentStatus status;
        private final LocalDate reservationDate;
        private final LocalDateTime paidAt;

        private PaymentListItem(Long id, String orderNumber, Long buyerId, String buyerName,
                                String procedureName, BigDecimal amount, PaymentStatus status,
                                LocalDate reservationDate, LocalDateTime paidAt) {
            this.id = id;
            this.orderNumber = orderNumber;
            this.buyerId = buyerId;
            this.buyerName = buyerName;
            this.procedureName = procedureName;
            this.amount = amount;
            this.status = status;
            this.reservationDate = reservationDate;
            this.paidAt = paidAt;
        }

        static PaymentListItem from(PaymentOrder order) {
            return new PaymentListItem(order.getId(), order.getOrderNumber(), order.getBuyer().getId(),
                PrivacyMasker.name(order.getBuyer().getName()), order.getProcedureProduct().getName(),
                order.getAmount(), order.getStatus(), order.getReservationDate(), order.getPaidAt());
        }

        public Long getId() { return id; }
        public String getOrderNumber() { return orderNumber; }
        public Long getBuyerId() { return buyerId; }
        public String getBuyerName() { return buyerName; }
        public String getProcedureName() { return procedureName; }
        public BigDecimal getAmount() { return amount; }
        public PaymentStatus getStatus() { return status; }
        public LocalDate getReservationDate() { return reservationDate; }
        public LocalDateTime getPaidAt() { return paidAt; }
    }

    @GetMapping("/admin/payments/{id}")
    public String detail(@PathVariable Long id, Model model) {
        model.addAttribute("order", paymentService.findById(id));
        return "admin/payment-detail";
    }

    @PostMapping("/admin/payments/{id}")
    public String update(
        @PathVariable Long id,
        @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate reservationDate,
        @RequestParam String adminPassword,
        Principal principal,
        RedirectAttributes redirectAttributes
    ) {
        try {
            reauthenticationService.verify(principal, adminPassword);
            paymentService.updateReservationDate(id, reservationDate);
            redirectAttributes.addFlashAttribute("message", "예약 날짜가 수정되었습니다.");
        } catch (IllegalArgumentException e) {
            redirectAttributes.addFlashAttribute("error", e.getMessage());
        }
        return "redirect:/admin/payments/" + id;
    }

    @PostMapping("/admin/payments/{id}/refund")
    public String refund(@PathVariable Long id,
                         @RequestParam String adminPassword,
                         Principal principal,
                         RedirectAttributes redirectAttributes) {
        try {
            reauthenticationService.verify(principal, adminPassword);
            paymentService.refund(id);
            redirectAttributes.addFlashAttribute("message", "환불 처리되었습니다. 사용 포인트는 반환하고 적립 포인트는 회수했습니다.");
        } catch (IllegalArgumentException e) {
            redirectAttributes.addFlashAttribute("error", e.getMessage());
        }
        return "redirect:/admin/payments/" + id;
    }
}
