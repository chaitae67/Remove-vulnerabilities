package com.example.clinic.service;

import com.example.clinic.domain.AppUser;
import com.example.clinic.domain.Coupon;
import com.example.clinic.domain.PaymentOrder;
import com.example.clinic.domain.PaymentStatus;
import com.example.clinic.domain.ProcedureProduct;
import com.example.clinic.repository.PaymentOrderRepository;
import java.math.BigDecimal;
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
    public PaymentOrder createPaidOrder(
        AppUser buyer,
        ProcedureProduct procedureProduct,
        String method,
        BigDecimal price,
        int quantity,
        BigDecimal discountAmount,
        BigDecimal fee,
        int usePoints,
        String couponCode
    ) {
        Coupon coupon = couponCode == null || couponCode.isBlank() ? null : couponService.findByCode(couponCode);
        BigDecimal originalAmount = price.multiply(BigDecimal.valueOf(quantity));
        BigDecimal finalAmount = originalAmount
            .subtract(discountAmount)
            .subtract(BigDecimal.valueOf(usePoints))
            .add(fee);
        int earnedPoints = finalAmount.intValue() / 100;
        buyer.setPointBalance(buyer.getPointBalance() - usePoints + earnedPoints);

        PaymentOrder order = new PaymentOrder();
        order.setOrderNumber("CLINIC-" + UUID.randomUUID().toString().substring(0, 8).toUpperCase());
        order.setBuyer(buyer);
        order.setProcedureProduct(procedureProduct);
        order.setOriginalAmount(originalAmount);
        order.setCoupon(coupon);
        order.setCouponDiscount(discountAmount.intValue());
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
