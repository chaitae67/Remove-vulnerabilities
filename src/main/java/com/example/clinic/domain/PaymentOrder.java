package com.example.clinic.domain;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.ManyToOne;
import jakarta.persistence.PrePersist;
import java.math.BigDecimal;
import java.time.LocalDateTime;

@Entity
public class PaymentOrder {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(nullable = false, unique = true, length = 40)
    private String orderNumber;

    @ManyToOne(optional = false)
    private AppUser buyer;

    @ManyToOne(optional = false)
    private ProcedureProduct procedureProduct;

    @Column(nullable = false, precision = 12, scale = 0)
    private BigDecimal amount;

    @Column(nullable = false, precision = 12, scale = 0)
    private BigDecimal originalAmount;

    @Column(nullable = false)
    private int couponDiscount;

    @Column(nullable = false)
    private int pointsUsed;

    @Column(nullable = false)
    private int earnedPoints;

    @ManyToOne
    private Coupon coupon;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 20)
    private PaymentStatus status = PaymentStatus.READY;

    @Column(length = 40)
    private String method;

    @Column(nullable = false)
    private LocalDateTime createdAt;

    private LocalDateTime paidAt;

    @PrePersist
    void prePersist() {
        createdAt = LocalDateTime.now();
    }

    public Long getId() {
        return id;
    }

    public String getOrderNumber() {
        return orderNumber;
    }

    public void setOrderNumber(String orderNumber) {
        this.orderNumber = orderNumber;
    }

    public AppUser getBuyer() {
        return buyer;
    }

    public void setBuyer(AppUser buyer) {
        this.buyer = buyer;
    }

    public ProcedureProduct getProcedureProduct() {
        return procedureProduct;
    }

    public void setProcedureProduct(ProcedureProduct procedureProduct) {
        this.procedureProduct = procedureProduct;
    }

    public BigDecimal getAmount() {
        return amount;
    }

    public void setAmount(BigDecimal amount) {
        this.amount = amount;
    }

    public BigDecimal getOriginalAmount() { return originalAmount; }
    public void setOriginalAmount(BigDecimal originalAmount) { this.originalAmount = originalAmount; }
    public int getCouponDiscount() { return couponDiscount; }
    public void setCouponDiscount(int couponDiscount) { this.couponDiscount = couponDiscount; }
    public int getPointsUsed() { return pointsUsed; }
    public void setPointsUsed(int pointsUsed) { this.pointsUsed = pointsUsed; }
    public int getEarnedPoints() { return earnedPoints; }
    public void setEarnedPoints(int earnedPoints) { this.earnedPoints = earnedPoints; }
    public Coupon getCoupon() { return coupon; }
    public void setCoupon(Coupon coupon) { this.coupon = coupon; }

    public PaymentStatus getStatus() {
        return status;
    }

    public void setStatus(PaymentStatus status) {
        this.status = status;
    }

    public String getMethod() {
        return method;
    }

    public void setMethod(String method) {
        this.method = method;
    }

    public LocalDateTime getCreatedAt() {
        return createdAt;
    }

    public LocalDateTime getPaidAt() {
        return paidAt;
    }

    public void setPaidAt(LocalDateTime paidAt) {
        this.paidAt = paidAt;
    }
}
