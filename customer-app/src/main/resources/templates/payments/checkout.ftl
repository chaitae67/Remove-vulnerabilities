<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>결제</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<div><#include "/fragments/header.ftl"></div>
<main class="narrow">
    <section class="panel">
        <#if error??><div class="flash error">${error}</div></#if>
        <p class="eyebrow">Payment</p>
        <h1>${procedure.name}</h1>
        <p>${procedure.summary}</p>
        <strong class="price">${numbers.formatInteger(procedure.price)}원</strong>
        <form id="payment-form" class="stack-form" action="/payments/checkout/${procedure.id?c}" method="post"
              data-unit-price="${procedure.price?c}">
            <input type="hidden" name="${_csrf.parameterName}" value="${_csrf.token}">
            <input name="quantity" type="hidden" value="1">

            <label for="reservationDate">예약 날짜</label>
            <input id="reservationDate" name="reservationDate" type="date" min="${minReservationDate}" required>

            <p>보유 포인트: <strong>${numbers.formatInteger(user.pointBalance)}P</strong></p>
            <label for="usePoints">사용할 포인트</label>
            <input id="usePoints" name="usePoints" type="number" value="0" min="0"
                   max="${user.pointBalance}" required>
            <p id="points-error" class="form-error" hidden>보유 포인트보다 많은 포인트를 사용할 수 없습니다.</p>

            <label for="couponCode">쿠폰</label>
            <select id="couponCode" name="couponCode">
                <option value="">쿠폰 사용 안 함</option>
                <#list coupons as coupon>
                <option value="${coupon.code}" data-discount="${coupon.discountAmount?c}">${coupon.name} (${numbers.formatInteger(coupon.discountAmount)}원)</option>
                </#list>
            </select>
            <label for="paymentMethod">결제 수단</label>
            <select id="paymentMethod" name="method" required>
                <option value="CARD">신용카드</option>
                <option value="BANK_TRANSFER">무통장입금</option>
                <option value="KAKAO_PAY">간편결제</option>
            </select>
            <fieldset id="cardFields">
                <legend>카드 인증</legend>
                <label for="cardNumber">카드번호</label>
                <input id="cardNumber" name="cardNumber" inputmode="numeric" autocomplete="cc-number"
                       placeholder="숫자 13~19자리" maxlength="23">
                <label for="cardExpiry">유효기간</label>
                <input id="cardExpiry" name="cardExpiry" inputmode="numeric" autocomplete="cc-exp"
                       placeholder="MM/YY" maxlength="5">
                <label for="cardPassword">카드 비밀번호 앞 2자리</label>
                <input id="cardPassword" name="cardPassword" type="password" inputmode="numeric"
                       autocomplete="off" pattern="[0-9]{2}" maxlength="2" placeholder="앞 2자리">
            </fieldset>
            <label for="accountPassword">계정 비밀번호 재확인</label>
            <input id="accountPassword" name="accountPassword" type="password"
                   autocomplete="current-password" required>
            <dl class="summary-list">
                <div><dt>상품 금액</dt><dd id="subtotal">0원</dd></div>
                <div><dt>총 할인 금액</dt><dd id="discount-display">0원</dd></div>
                <div><dt>결제 금액</dt><dd id="total">0원</dd></div>
            </dl>

            <button class="button" type="submit">결제 완료</button>
        </form>
    </section>
</main>
<div><#include "/fragments/footer.ftl"></div>
<script src="/js/payment-checkout.js" defer></script>
</body>
</html>
