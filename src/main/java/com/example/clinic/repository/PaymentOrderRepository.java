package com.example.clinic.repository;

import java.util.List;
import java.util.Optional;

import org.springframework.data.jpa.repository.JpaRepository;

import com.example.clinic.domain.AppUser;
import com.example.clinic.domain.PaymentOrder;

public interface PaymentOrderRepository extends JpaRepository<PaymentOrder, Long> {
    Optional<PaymentOrder> findByOrderNumber(String orderNumber);

    List<PaymentOrder> findTop10ByOrderByCreatedAtDesc();

    List<PaymentOrder> findByBuyerOrderByCreatedAtDesc(AppUser buyer);
}
