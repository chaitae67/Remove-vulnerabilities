package com.example.clinic.service;

import com.example.clinic.domain.AppUser;
import com.example.clinic.domain.PaymentOrder;
import com.example.clinic.domain.PointHistory;
import com.example.clinic.domain.PointType;
import com.example.clinic.repository.AppUserRepository;
import com.example.clinic.repository.PointHistoryRepository;
import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.List;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * 회원 포인트 적립/사용을 담당한다.
 * 결제 금액의 EARN_RATE만큼을 결제 완료 시 적립하고, 결제 시 입력한 포인트만큼 차감한다.
 */
@Service
public class PointService {

    /** 결제 확정 금액 대비 적립률 (2%). */
    private static final BigDecimal EARN_RATE = new BigDecimal("0.02");

    /** 신규 가입 시 지급하는 웰컴 포인트. */
    public static final int SIGNUP_BONUS = 2000;

    private final AppUserRepository userRepository;
    private final PointHistoryRepository pointHistoryRepository;

    public PointService(AppUserRepository userRepository, PointHistoryRepository pointHistoryRepository) {
        this.userRepository = userRepository;
        this.pointHistoryRepository = pointHistoryRepository;
    }

    public int getBalance(AppUser user) {
        Integer points = user.getPoints();
        return points == null ? 0 : points;
    }

    /**
     * 결제 시 포인트를 차감한다. 보유 포인트보다 많이 사용하려 하면 거부한다.
     */
    @Transactional
    public void usePoints(AppUser user, int amount, PaymentOrder order) {
        if (amount <= 0) {
            return;
        }
        int balance = getBalance(user);
        if (amount > balance) {
            throw new IllegalArgumentException("보유 포인트가 부족합니다.");
        }
        int newBalance = balance - amount;
        user.setPoints(newBalance);
        userRepository.save(user);
        saveHistory(user, PointType.USE, amount, newBalance, order, "결제 시 포인트 사용");
    }

    /**
     * 결제 확정 금액을 기준으로 포인트를 적립한다.
     *
     * @return 실제로 적립된 포인트 수
     */
    @Transactional
    public int earnPoints(AppUser user, BigDecimal paidAmount, PaymentOrder order) {
        if (paidAmount == null || paidAmount.signum() <= 0) {
            return 0;
        }
        int earned = paidAmount.multiply(EARN_RATE).setScale(0, RoundingMode.DOWN).intValueExact();
        if (earned <= 0) {
            return 0;
        }
        int newBalance = getBalance(user) + earned;
        user.setPoints(newBalance);
        userRepository.save(user);
        saveHistory(user, PointType.EARN, earned, newBalance, order, "결제 적립");
        return earned;
    }

    /**
     * 회원가입 축하 포인트를 지급한다.
     */
    @Transactional
    public void grantSignupBonus(AppUser user) {
        int newBalance = getBalance(user) + SIGNUP_BONUS;
        user.setPoints(newBalance);
        userRepository.save(user);
        saveHistory(user, PointType.EARN, SIGNUP_BONUS, newBalance, null, "회원가입 축하 포인트");
    }

    public List<PointHistory> findHistory(AppUser user) {
        return pointHistoryRepository.findByUserOrderByCreatedAtDesc(user);
    }

    private void saveHistory(AppUser user, PointType type, int amount, int balanceAfter, PaymentOrder order, String memo) {
        PointHistory history = new PointHistory();
        history.setUser(user);
        history.setType(type);
        history.setAmount(amount);
        history.setBalanceAfter(balanceAfter);
        history.setOrder(order);
        history.setMemo(memo);
        pointHistoryRepository.save(history);
    }
}
