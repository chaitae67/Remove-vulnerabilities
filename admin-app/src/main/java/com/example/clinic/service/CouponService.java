package com.example.clinic.service;

import com.example.clinic.domain.Coupon;
import com.example.clinic.repository.CouponRepository;
import java.util.List;
import org.springframework.stereotype.Service;

@Service
public class CouponService {
    private final CouponRepository couponRepository;

    public CouponService(CouponRepository couponRepository) {
        this.couponRepository = couponRepository;
    }

    public List<Coupon> findActiveCoupons() {
        return couponRepository.findByActiveTrueOrderByIdAsc().stream()
            .filter(coupon -> !"ADMIN50000".equals(coupon.getCode()))
            .toList();
    }

    public Coupon findByCode(String code) {
        return couponRepository.findByCode(code)
            .orElseThrow(() -> new IllegalArgumentException("쿠폰을 찾을 수 없습니다."));
    }
}
