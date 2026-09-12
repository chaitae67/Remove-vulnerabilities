package com.example.clinic.service;

import com.example.clinic.domain.Coupon;
import com.example.clinic.repository.CouponRepository;
import java.time.LocalDate;
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

    public List<Coupon> findAll() {
        return couponRepository.findAll();
    }

    /**
     * 이벤트 쿠폰을 발급한다. (실습용) 서버측 값 검증 없이 요청값을 그대로 저장하므로
     * 할인액 상한/음수 검사, 코드 형식 검사, 발급 권한 재확인이 빠져 있다.
     */
    public Coupon issue(String code, String name, int discountAmount, LocalDate expiresAt) {
        Coupon coupon = couponRepository.findByCode(code).orElseGet(Coupon::new);
        coupon.setCode(code);
        coupon.setName(name);
        coupon.setDiscountAmount(discountAmount);
        coupon.setExpiresAt(expiresAt);
        coupon.setActive(true);
        return couponRepository.save(coupon);
    }
}
