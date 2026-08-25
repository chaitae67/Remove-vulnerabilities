package com.example.clinic.repository;

import java.util.List;
import java.util.Optional;

import org.springframework.data.jpa.repository.JpaRepository;

import com.example.clinic.domain.AppUser;
import com.example.clinic.domain.Coupon;
import com.example.clinic.domain.PaymentOrder;
import com.example.clinic.domain.PaymentStatus;

public interface PaymentOrderRepository extends JpaRepository<PaymentOrder, Long> {
    Optional<PaymentOrder> findByOrderNumber(String orderNumber);

    Optional<PaymentOrder> findByOrderNumberAndBuyer(String orderNumber, AppUser buyer);

    boolean existsByBuyerAndCouponAndStatus(AppUser buyer, Coupon coupon, PaymentStatus status);

    List<PaymentOrder> findTop10ByOrderByCreatedAtDesc();

    List<PaymentOrder> findByBuyerOrderByCreatedAtDesc(AppUser buyer);
}
