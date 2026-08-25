package com.example.clinic.service;

import com.example.clinic.domain.AppUser;
import com.example.clinic.domain.Coupon;
import com.example.clinic.domain.PaymentOrder;
import com.example.clinic.domain.PaymentStatus;
import com.example.clinic.domain.ProcedureProduct;
import com.example.clinic.repository.PaymentOrderRepository;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.time.LocalDate;
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
        int quantity,
        int usePoints,
        String couponCode,
        LocalDate reservationDate
    ) {
        Coupon coupon = couponCode == null || couponCode.isBlank() ? null : couponService.findByCode(couponCode);
        if (quantity < 1) {
            throw new IllegalArgumentException("수량은 1개 이상이어야 합니다.");
        }
        if (reservationDate == null || reservationDate.isBefore(LocalDate.now())) {
            throw new IllegalArgumentException("예약 날짜를 오늘 이후로 선택해 주세요.");
        }
        if (usePoints < 0 || usePoints > buyer.getPointBalance()) {
            throw new IllegalArgumentException("사용할 포인트를 다시 확인해 주세요.");
        }
        if (coupon != null && (!coupon.isActive() || (coupon.getExpiresAt() != null && coupon.getExpiresAt().isBefore(LocalDate.now())))) {
            throw new IllegalArgumentException("사용할 수 없는 쿠폰입니다.");
        }
        if (coupon != null && paymentOrderRepository.existsByBuyerAndCouponAndStatus(buyer, coupon, PaymentStatus.PAID)) {
            throw new IllegalArgumentException("이미 사용한 쿠폰입니다.");
        }

        BigDecimal originalAmount = procedureProduct.getPrice().multiply(BigDecimal.valueOf(quantity));
        int couponDiscount = coupon == null ? 0 : coupon.getDiscountAmount();
        BigDecimal payableBeforePoints = originalAmount.subtract(BigDecimal.valueOf(couponDiscount)).max(BigDecimal.ZERO);
        if (BigDecimal.valueOf(usePoints).compareTo(payableBeforePoints) > 0) {
            throw new IllegalArgumentException("결제 금액보다 많은 포인트를 사용할 수 없습니다.");
        }
        BigDecimal finalAmount = originalAmount
            .subtract(BigDecimal.valueOf(couponDiscount))
            .subtract(BigDecimal.valueOf(usePoints))
            .max(BigDecimal.ZERO);
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
        order.setReservationDate(reservationDate);
        return paymentOrderRepository.save(order);
    }

    public PaymentOrder findByOrderNumber(String orderNumber) {
        return paymentOrderRepository.findByOrderNumber(orderNumber)
            .orElseThrow(() -> new IllegalArgumentException("결제 내역을 찾을 수 없습니다."));
    }

    public PaymentOrder findByOrderNumberAndBuyer(String orderNumber, AppUser buyer) {
        return paymentOrderRepository.findByOrderNumberAndBuyer(orderNumber, buyer)
            .orElseThrow(() -> new IllegalArgumentException("결제 내역을 찾을 수 없습니다."));
    }

    public List<Coupon> findAvailableCoupons(AppUser buyer) {
        return couponService.findActiveCoupons().stream()
            .filter(coupon -> coupon.getExpiresAt() == null || !coupon.getExpiresAt().isBefore(LocalDate.now()))
            .filter(coupon -> !paymentOrderRepository.existsByBuyerAndCouponAndStatus(buyer, coupon, PaymentStatus.PAID))
            .toList();
    }

    public List<PaymentOrder> findRecentOrders() {
        return paymentOrderRepository.findTop10ByOrderByCreatedAtDesc();
    }
}
