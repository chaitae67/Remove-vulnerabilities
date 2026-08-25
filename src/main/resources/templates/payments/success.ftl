<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>결제 완료</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<#include "/fragments/header.ftl">
<main class="narrow">
    <section class="panel success-panel">
        <p class="eyebrow">Payment Complete</p>
        <h1>결제가 완료되었습니다.</h1>
        <dl class="summary-list">
            <div><dt>주문번호</dt><dd>${order.orderNumber}</dd></div>
            <div><dt>상품</dt><dd>${order.procedureProduct.name}</dd></div>
            <div><dt>상품금액</dt><dd>${order.originalAmount?string("#,##0")}원</dd></div>
            <div><dt>쿠폰 할인</dt><dd>-${order.couponDiscount?string("#,##0")}원</dd></div>
            <div><dt>포인트 사용</dt><dd>-${order.pointsUsed?string("#,##0")}P</dd></div>
            <div><dt>금액</dt><dd>${order.amount?string("#,##0")}원</dd></div>
            <div><dt>적립 포인트</dt><dd>${order.earnedPoints?string("#,##0")}P</dd></div>
            <div><dt>상태</dt><dd>${order.status}</dd></div>
        </dl>
        <a class="button" href="/">홈으로</a>
    </section>
</main>
<#include "/fragments/footer.ftl">
</body>
</html>
