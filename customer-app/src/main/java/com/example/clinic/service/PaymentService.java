package com.example.clinic.service;

import com.example.clinic.domain.AppUser;
import com.example.clinic.domain.Coupon;
import com.example.clinic.domain.PaymentOrder;
import com.example.clinic.domain.PaymentStatus;
import com.example.clinic.domain.ProcedureProduct;
import com.example.clinic.repository.PaymentOrderRepository;
import com.example.clinic.repository.AppUserRepository;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;
import java.time.YearMonth;
import java.time.format.DateTimeFormatter;
import java.time.format.DateTimeParseException;
import java.util.Set;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class PaymentService {

    private static final Set<String> ALLOWED_METHODS = Set.of("CARD", "BANK_TRANSFER", "KAKAO_PAY");

    private final PaymentOrderRepository paymentOrderRepository;
    private final CouponService couponService;
    private final AppUserRepository appUserRepository;

    public PaymentService(
        PaymentOrderRepository paymentOrderRepository,
        CouponService couponService,
        AppUserRepository appUserRepository
    ) {
        this.paymentOrderRepository = paymentOrderRepository;
        this.couponService = couponService;
        this.appUserRepository = appUserRepository;
    }

    @Transactional
    public PaymentOrder createPaidOrder(
        AppUser buyer,
        ProcedureProduct procedureProduct,
        String method,
        int quantity,
        int usePoints,
        String couponCode,
        LocalDate reservationDate,
        String cardNumber,
        String cardExpiry,
        String cardPassword
    ) {
        validatePaymentCredentials(method, cardNumber, cardExpiry, cardPassword);
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

        // PV-13: 결제 단가는 클라이언트 입력이 아니라 서버에 저장된 시술 정가만 사용한다(금액 변조 방지).
        BigDecimal unitPrice = procedureProduct.getPrice();
        BigDecimal originalAmount = unitPrice.multiply(BigDecimal.valueOf(quantity));
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
        appUserRepository.save(buyer);

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

    private void validatePaymentCredentials(String method, String cardNumber, String cardExpiry, String cardPassword) {
        if (!ALLOWED_METHODS.contains(method)) {
            throw new IllegalArgumentException("지원하지 않는 결제 수단입니다.");
        }
        if (!"CARD".equals(method)) {
            return;
        }
        String digits = cardNumber == null ? "" : cardNumber.replaceAll("[^0-9]", "");
        if (digits.length() < 13 || digits.length() > 19 || !passesLuhn(digits)) {
            throw new IllegalArgumentException("카드번호를 다시 확인해 주세요.");
        }
        if (cardPassword == null || !cardPassword.matches("\\d{2}")) {
            throw new IllegalArgumentException("카드 비밀번호 앞 2자리를 입력해 주세요.");
        }
        try {
            YearMonth expiry = YearMonth.parse(cardExpiry, DateTimeFormatter.ofPattern("MM/yy"));
            if (expiry.isBefore(YearMonth.now())) {
                throw new IllegalArgumentException("카드 유효기간이 만료되었습니다.");
            }
        } catch (DateTimeParseException | NullPointerException exception) {
            throw new IllegalArgumentException("카드 유효기간을 MM/YY 형식으로 입력해 주세요.");
        }
        // 카드번호·유효기간·비밀번호는 검증 후 즉시 폐기하며 DB나 로그에 저장하지 않는다.
    }

    private boolean passesLuhn(String digits) {
        int sum = 0;
        boolean doubleDigit = false;
        for (int i = digits.length() - 1; i >= 0; i--) {
            int value = digits.charAt(i) - '0';
            if (doubleDigit) {
                value *= 2;
                if (value > 9) value -= 9;
            }
            sum += value;
            doubleDigit = !doubleDigit;
        }
        return sum % 10 == 0;
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
