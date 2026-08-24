package com.example.clinic.service;

import com.example.clinic.domain.AppUser;
import com.example.clinic.domain.UserCoupon;
import com.example.clinic.repository.UserCouponRepository;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.List;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * 회원별로 발급된 쿠폰(UserCoupon) 조회/검증/사용 처리를 담당한다.
 */
@Service
public class CouponService {

    private final UserCouponRepository userCouponRepository;

    public CouponService(UserCouponRepository userCouponRepository) {
        this.userCouponRepository = userCouponRepository;
    }

    /** 현재 사용 가능한(미사용·활성·유효기간 이내) 쿠폰 목록. */
    public List<UserCoupon> findAvailableCoupons(AppUser user) {
        LocalDateTime now = LocalDateTime.now();
        return userCouponRepository.findByUserAndUsedFalseOrderByIssuedAtDesc(user).stream()
            .filter(uc -> uc.getCoupon().isActive())
            .filter(uc -> uc.getCoupon().getExpiresAt() == null || uc.getCoupon().getExpiresAt().isAfter(now))
            .toList();
    }

    public List<UserCoupon> findAllByUser(AppUser user) {
        return userCouponRepository.findByUserOrderByIssuedAtDesc(user);
    }

    /**
     * 결제에 사용하려는 쿠폰이 이 회원 소유이고, 사용 가능한 상태인지 검증한다.
     * 소유자 검증(findByIdAndUser)을 통해 다른 회원의 쿠폰 발급 건 id를 넣어도 사용할 수 없도록 막는다.
     */
    public UserCoupon getUsableCoupon(AppUser user, Long userCouponId, BigDecimal orderAmount) {
        UserCoupon userCoupon = userCouponRepository.findByIdAndUser(userCouponId, user)
            .orElseThrow(() -> new IllegalArgumentException("사용할 수 없는 쿠폰입니다."));

        if (userCoupon.isUsed()) {
            throw new IllegalArgumentException("이미 사용한 쿠폰입니다.");
        }
        if (!userCoupon.getCoupon().isActive()) {
            throw new IllegalArgumentException("사용할 수 없는 쿠폰입니다.");
        }
        LocalDateTime expiresAt = userCoupon.getCoupon().getExpiresAt();
        if (expiresAt != null && expiresAt.isBefore(LocalDateTime.now())) {
            throw new IllegalArgumentException("유효기간이 지난 쿠폰입니다.");
        }
        BigDecimal minOrderAmount = userCoupon.getCoupon().getMinOrderAmount();
        if (minOrderAmount != null && orderAmount.compareTo(minOrderAmount) < 0) {
            throw new IllegalArgumentException("최소 주문 금액을 충족하지 않는 쿠폰입니다.");
        }
        return userCoupon;
    }

    @Transactional
    public void markUsed(UserCoupon userCoupon) {
        userCoupon.setUsed(true);
        userCoupon.setUsedAt(LocalDateTime.now());
        userCouponRepository.save(userCoupon);
    }
}
