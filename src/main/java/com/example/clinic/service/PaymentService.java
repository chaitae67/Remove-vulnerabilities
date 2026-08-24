package com.example.clinic.service;

import com.example.clinic.domain.AppUser;
import com.example.clinic.domain.PaymentOrder;
import com.example.clinic.domain.PaymentStatus;
import com.example.clinic.domain.ProcedureProduct;
import com.example.clinic.domain.UserCoupon;
import com.example.clinic.repository.PaymentOrderRepository;
import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.LocalDateTime;
import java.util.List;
import java.util.UUID;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class PaymentService {

    private final PaymentOrderRepository paymentOrderRepository;
    private final PointService pointService;
    private final CouponService couponService;

    public PaymentService(PaymentOrderRepository paymentOrderRepository,
                           PointService pointService,
                           CouponService couponService) {
        this.paymentOrderRepository = paymentOrderRepository;
        this.pointService = pointService;
        this.couponService = couponService;
    }

    /**
     * 시술 상품을 결제한다. 서버가 상품 가격을 기준으로 최종 결제 금액을 다시 계산하므로,
     * 클라이언트가 보낸 금액은 신뢰하지 않고 포인트 사용량/쿠폰 id만 입력값으로 받는다.
     *
     * @param usePoints    이번 결제에 사용할 포인트 (없으면 0)
     * @param userCouponId 이번 결제에 사용할 쿠폰 발급 건 id (없으면 null)
     */
    @Transactional
    public PaymentOrder createPaidOrder(AppUser buyer, ProcedureProduct procedureProduct, String method,
                                         Integer usePoints, Long userCouponId) {
        BigDecimal price = procedureProduct.getPrice();

        int pointsToUse = usePoints == null ? 0 : Math.max(0, usePoints);
        int balance = pointService.getBalance(buyer);
        if (pointsToUse > balance) {
            throw new IllegalArgumentException("보유 포인트가 부족합니다.");
        }
        // 상품 가격을 넘는 포인트는 사용할 수 없다.
        if (BigDecimal.valueOf(pointsToUse).compareTo(price) > 0) {
            pointsToUse = price.setScale(0, RoundingMode.DOWN).intValueExact();
        }

        BigDecimal remainingAfterPoints = price.subtract(BigDecimal.valueOf(pointsToUse));

        UserCoupon userCoupon = null;
        BigDecimal couponDiscount = BigDecimal.ZERO;
        if (userCouponId != null) {
            userCoupon = couponService.getUsableCoupon(buyer, userCouponId, price);
            couponDiscount = userCoupon.getCoupon().getDiscountAmount();
            if (couponDiscount.compareTo(remainingAfterPoints) > 0) {
                couponDiscount = remainingAfterPoints;
            }
        }

        BigDecimal finalAmount = remainingAfterPoints.subtract(couponDiscount);
        if (finalAmount.signum() < 0) {
            finalAmount = BigDecimal.ZERO;
        }

        PaymentOrder order = new PaymentOrder();
        order.setOrderNumber("CLINIC-" + UUID.randomUUID().toString().substring(0, 8).toUpperCase());
        order.setBuyer(buyer);
        order.setProcedureProduct(procedureProduct);
        order.setProductPrice(price);
        order.setPointsUsed(pointsToUse);
        order.setCouponDiscount(couponDiscount);
        order.setUserCoupon(userCoupon);
        order.setAmount(finalAmount);
        order.setMethod(method);
        order.setStatus(PaymentStatus.PAID);
        order.setPaidAt(LocalDateTime.now());
        order = paymentOrderRepository.save(order);

        if (pointsToUse > 0) {
            pointService.usePoints(buyer, pointsToUse, order);
        }
        if (userCoupon != null) {
            couponService.markUsed(userCoupon);
        }

        int earned = pointService.earnPoints(buyer, finalAmount, order);
        order.setPointsEarned(earned);
        order = paymentOrderRepository.save(order);

        return order;
    }

    public PaymentOrder findByOrderNumber(String orderNumber) {
        return paymentOrderRepository.findByOrderNumber(orderNumber)
            .orElseThrow(() -> new IllegalArgumentException("결제 내역을 찾을 수 없습니다."));
    }

    public List<PaymentOrder> findRecentOrders() {
        return paymentOrderRepository.findTop10ByOrderByCreatedAtDesc();
    }
}
