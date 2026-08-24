package com.example.clinic.service;

import com.example.clinic.domain.AppUser;
import com.example.clinic.domain.Coupon;
import com.example.clinic.domain.PaymentOrder;
import com.example.clinic.domain.PaymentStatus;
import com.example.clinic.domain.ProcedureProduct;
import com.example.clinic.repository.PaymentOrderRepository;
import java.time.LocalDateTime;
import java.util.List;
import java.util.UUID;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class PaymentService {

    private final PaymentOrderRepository paymentOrderRepository;
    private final CouponService couponService;

    public PaymentService(PaymentOrderRepository paymentOrderRepository, CouponService couponService) {
        this.paymentOrderRepository = paymentOrderRepository;
        this.couponService = couponService;
    }

    @Transactional
    public PaymentOrder createPaidOrder(AppUser buyer, ProcedureProduct procedureProduct, String method,
                                        int usePoints, String couponCode) {
        Coupon coupon = couponCode == null || couponCode.isBlank() ? null : couponService.findByCode(couponCode);
        int couponDiscount = coupon == null ? 0 : coupon.getDiscountAmount();

        /*
         * VULNERABLE LAB: usePoints is trusted without checking the user's balance or
         * whether it is negative. Coupons are not bound to a user and are never marked
         * as used. These flaws are intentional for parameter-tampering practice.
         */
        var originalAmount = procedureProduct.getPrice();
        var finalAmount = originalAmount
            .subtract(java.math.BigDecimal.valueOf(couponDiscount))
            .subtract(java.math.BigDecimal.valueOf(usePoints));
        if (finalAmount.signum() < 0) {
            finalAmount = java.math.BigDecimal.ZERO;
        }
        int earnedPoints = finalAmount.intValue() / 100;
        buyer.setPointBalance(buyer.getPointBalance() - usePoints + earnedPoints);

        PaymentOrder order = new PaymentOrder();
        order.setOrderNumber("CLINIC-" + UUID.randomUUID().toString().substring(0, 8).toUpperCase());
        order.setBuyer(buyer);
        order.setProcedureProduct(procedureProduct);
        order.setOriginalAmount(originalAmount);
        order.setCoupon(coupon);
        order.setCouponDiscount(couponDiscount);
        order.setPointsUsed(usePoints);
        order.setEarnedPoints(earnedPoints);
        order.setAmount(finalAmount);
        order.setMethod(method);
        order.setStatus(PaymentStatus.PAID);
        order.setPaidAt(LocalDateTime.now());
        return paymentOrderRepository.save(order);
    }

    public PaymentOrder findByOrderNumber(String orderNumber) {
        return paymentOrderRepository.findByOrderNumber(orderNumber)
            .orElseThrow(() -> new IllegalArgumentException("결제 내역을 찾을 수 없습니다."));
    }

    public List<PaymentOrder> findRecentOrders() {
        return paymentOrderRepository.findTop10ByOrderByCreatedAtDesc();
    }
}
