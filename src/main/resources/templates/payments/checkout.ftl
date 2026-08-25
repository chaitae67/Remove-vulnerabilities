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
        <p class="eyebrow">Payment</p>
        <h1>${procedure.name}</h1>
        <p>${procedure.summary}</p>
        <strong class="price">${numbers.formatInteger(procedure.price)}원</strong>
        <form id="payment-form" class="stack-form" action="/payments/checkout/${procedure.id}" method="post">
            <input type="hidden" name="${_csrf.parameterName}" value="${_csrf.token}">
            <label for="quantity">수량</label>
            <input id="quantity" name="quantity" type="number" value="1" min="1" required>

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
            <select name="method" required>
                <option value="CARD">신용카드</option>
                <option value="BANK_TRANSFER">무통장입금</option>
                <option value="KAKAO_PAY">간편결제</option>
            </select>
            <input placeholder="카드번호 입력" value="4242-4242-4242-4242">
            <dl class="summary-list">
                <div><dt>상품 금액</dt><dd id="subtotal">0원</dd></div>
                <div><dt>할인 금액</dt><dd id="discount-display">0원</dd></div>
                <div><dt>결제 금액</dt><dd id="total">0원</dd></div>
            </dl>

            <input id="price" name="price" type="hidden" value="${procedure.price?c}">
            <input id="discountAmount" name="discountAmount" type="hidden" value="0">
            <input id="fee" name="fee" type="hidden" value="0">
            <button class="button" type="submit">결제 완료</button>
        </form>
    </section>
</main>
<div><#include "/fragments/footer.ftl"></div>
<#noparse>
<script>
	    const priceInput = document.getElementById('price');
	    const paymentForm = document.getElementById('payment-form');
	    const quantityInput = document.getElementById('quantity');
	    const couponInput = document.getElementById('couponCode');
	    const discountInput = document.getElementById('discountAmount');
	    const feeInput = document.getElementById('fee');
	    const pointsInput = document.getElementById('usePoints');
	    const pointsError = document.getElementById('points-error');
	    const toNumber = value => Number(String(value || 0).replace(/,/g, '')) || 0;

    function formatWon(value) {
        const amount = Number(String(value || 0).replace(/,/g, ''));
        return `${Number.isFinite(amount) ? amount.toLocaleString('ko-KR') : '0'}원`;
    }

	    function updateAmount() {
	        const price = toNumber(priceInput.value);
	        const quantity = toNumber(quantityInput.value);
	        const discount = toNumber(discountInput.value);
	        const fee = toNumber(feeInput.value);
	        const points = toNumber(pointsInput.value);
	        const maxPoints = toNumber(pointsInput.max);
	        const subtotal = price * quantity;
	        const pointsExceeded = points > maxPoints;
	        pointsInput.setCustomValidity(pointsExceeded ? '보유 포인트보다 많은 포인트를 사용할 수 없습니다.' : '');
	        pointsError.hidden = !pointsExceeded;

	        document.getElementById('subtotal').textContent = formatWon(subtotal);
	        document.getElementById('discount-display').textContent = formatWon(discount);
	        document.getElementById('total').textContent = formatWon(subtotal - discount - points + fee);
	    }

    couponInput.addEventListener('change', () => {
        const option = couponInput.options[couponInput.selectedIndex];
        discountInput.value = option.dataset.discount || 0;
        updateAmount();
    });

    quantityInput.addEventListener('input', () => {
        updateAmount();
    });
	    pointsInput.addEventListener('input', updateAmount);
	    paymentForm.addEventListener('submit', event => {
	        updateAmount();
	        if (!paymentForm.checkValidity()) {
	            event.preventDefault();
	            pointsInput.reportValidity();
	        }
	    });

	    updateAmount();
</script>
</#noparse>
</body>
</html>
