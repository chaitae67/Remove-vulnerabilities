package com.example.clinic.repository;

import com.example.clinic.domain.AppUser;
import com.example.clinic.domain.UserCoupon;
import java.util.List;
import java.util.Optional;
import org.springframework.data.jpa.repository.JpaRepository;

public interface UserCouponRepository extends JpaRepository<UserCoupon, Long> {
    List<UserCoupon> findByUserOrderByIssuedAtDesc(AppUser user);

    List<UserCoupon> findByUserAndUsedFalseOrderByIssuedAtDesc(AppUser user);

    Optional<UserCoupon> findByIdAndUser(Long id, AppUser user);
}
