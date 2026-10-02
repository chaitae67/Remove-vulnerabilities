document.addEventListener('DOMContentLoaded', () => {
    const form = document.getElementById('payment-form');
    if (!form) return;

    const method = document.getElementById('paymentMethod');
    const cardFields = document.getElementById('cardFields');
    const cardInputs = ['cardNumber', 'cardExpiry', 'cardPassword'].map(id => document.getElementById(id));
    const coupon = document.getElementById('couponCode');
    const points = document.getElementById('usePoints');
    const pointsError = document.getElementById('points-error');
    const unitPrice = Number(form.dataset.unitPrice || 0);

    const asNumber = value => Number(String(value || 0).replace(/,/g, '')) || 0;
    const won = value => `${Math.max(0, value).toLocaleString('ko-KR')}원`;

    function updateCardFields() {
        const cardSelected = method.value === 'CARD';
        cardFields.hidden = !cardSelected;
        cardInputs.forEach(input => {
            input.required = cardSelected;
            if (!cardSelected) input.value = '';
        });
    }

    function updateAmount() {
        const option = coupon.options[coupon.selectedIndex];
        const discount = asNumber(option.dataset.discount);
        const usedPoints = asNumber(points.value);
        const pointsExceeded = usedPoints > asNumber(points.max);
        points.setCustomValidity(pointsExceeded ? '보유 포인트보다 많은 포인트를 사용할 수 없습니다.' : '');
        pointsError.hidden = !pointsExceeded;
        document.getElementById('subtotal').textContent = won(unitPrice);
        document.getElementById('discount-display').textContent = won(discount + usedPoints);
        document.getElementById('total').textContent = won(unitPrice - discount - usedPoints);
    }

    method.addEventListener('change', updateCardFields);
    coupon.addEventListener('change', updateAmount);
    points.addEventListener('input', updateAmount);
    form.addEventListener('submit', event => {
        updateCardFields();
        updateAmount();
        if (!form.checkValidity()) {
            event.preventDefault();
            form.reportValidity();
        }
    });
    updateCardFields();
    updateAmount();
});
