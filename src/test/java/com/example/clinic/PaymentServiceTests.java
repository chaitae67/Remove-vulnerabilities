package com.example.clinic;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import java.math.BigDecimal;
import java.time.LocalDate;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import com.example.clinic.domain.AppUser;
import com.example.clinic.domain.Coupon;
import com.example.clinic.domain.PaymentOrder;
import com.example.clinic.domain.PaymentStatus;
import com.example.clinic.domain.ProcedureProduct;
import com.example.clinic.repository.PaymentOrderRepository;
import com.example.clinic.repository.AppUserRepository;
import com.example.clinic.service.CouponService;
import com.example.clinic.service.PaymentService;

class PaymentServiceTests {
    private PaymentOrderRepository orderRepository;
    private CouponService couponService;
    private AppUserRepository appUserRepository;
    private PaymentService paymentService;
    private AppUser buyer;
    private ProcedureProduct product;
    private Coupon coupon;

    @BeforeEach
    void setUp() {
        orderRepository = mock(PaymentOrderRepository.class);
        couponService = mock(CouponService.class);
        appUserRepository = mock(AppUserRepository.class);
        paymentService = new PaymentService(orderRepository, couponService, appUserRepository);
        buyer = new AppUser();
        buyer.setPointBalance(5000);
        product = new ProcedureProduct();
        product.setPrice(new BigDecimal("120000"));
        coupon = new Coupon();
        coupon.setCode("WELCOME10000");
        coupon.setName("신규 회원 할인");
        coupon.setDiscountAmount(10000);
        coupon.setActive(true);
        when(couponService.findByCode("WELCOME10000")).thenReturn(coupon);
        when(orderRepository.save(any(PaymentOrder.class))).thenAnswer(invocation -> invocation.getArgument(0));
    }

    @Test
    void calculatesAmountFromServerProductAndCoupon() {
        PaymentOrder order = paymentService.createPaidOrder(buyer, product, "CARD", 1, 0, "WELCOME10000", LocalDate.now().plusDays(1));

        assertThat(order.getOriginalAmount()).isEqualByComparingTo("120000");
        assertThat(order.getCouponDiscount()).isEqualTo(10000);
        assertThat(order.getAmount()).isEqualByComparingTo("110000");
        assertThat(order.getReservationDate()).isEqualTo(LocalDate.now().plusDays(1));
    }

    @Test
    void rejectsCouponAlreadyUsedByBuyer() {
        when(orderRepository.existsByBuyerAndCouponAndStatus(buyer, coupon, PaymentStatus.PAID)).thenReturn(true);

        assertThatThrownBy(() -> paymentService.createPaidOrder(buyer, product, "CARD", 1, 0, "WELCOME10000", LocalDate.now().plusDays(1)))
            .isInstanceOf(IllegalArgumentException.class)
            .hasMessage("이미 사용한 쿠폰입니다.");
    }

    @Test
    void persistsPointBalanceAfterUsingAndEarningPoints() {
        PaymentOrder order = paymentService.createPaidOrder(
            buyer,
            product,
            "CARD",
            1,
            5000,
            null,
            LocalDate.now().plusDays(1)
        );

        assertThat(order.getPointsUsed()).isEqualTo(5000);
        assertThat(order.getEarnedPoints()).isEqualTo(1150);
        assertThat(buyer.getPointBalance()).isEqualTo(1150);
        org.mockito.Mockito.verify(appUserRepository).save(buyer);
    }
}
