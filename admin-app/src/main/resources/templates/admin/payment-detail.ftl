<#assign navActive = "payments">
<#import "/admin/_macros.ftl" as fmt>
<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>결제 상세 - Zero Day Clinic 관리자</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<#include "/admin/_header.ftl">
<main class="admin-page admin-detail">
    <section class="page-title">
        <p class="eyebrow">ORDER ${order.orderNumber?html}</p>
        <h1>결제 상세 <span class="state ${fmt.statusClass(order.status?string)}">${fmt.statusLabel(order.status?string)}</span></h1>
        <p><a class="back-link" href="/admin/payments">← 결제 목록</a></p>
    </section>

    <section class="content-band admin-detail-grid">
        <div class="panel">
            <h2>결제 정보 수정</h2>
            <#if order.status?string == 'CANCELED'>
            <p class="muted-box">환불된 결제 건은 수정할 수 없습니다.</p>
            <#else>
            <form action="/admin/payments/${order.id}" method="post" class="stack-form">
                <input type="hidden" name="${_csrf.parameterName}" value="${_csrf.token}">
                <label>결제 금액 (원)<input name="amount" type="number" min="0" step="1" value="${order.amount?string.computer}" required></label>
                <label>결제 수단<input name="method" value="${(order.method!'')?html}"></label>
                <label>예약 날짜<input name="reservationDate" type="date" value="<#if order.reservationDate??>${temporals.format(order.reservationDate, 'yyyy-MM-dd')}</#if>"></label>
                <div class="form-actions">
                    <button class="button" type="submit">저장</button>
                </div>
            </form>
            </#if>

            <#if order.status?string == 'PAID'>
            <form action="/admin/payments/${order.id}/refund" method="post" class="danger-form" onsubmit="return confirm('환불 처리하시겠습니까? 사용 포인트는 반환되고 적립 포인트는 회수됩니다.');">
                <input type="hidden" name="${_csrf.parameterName}" value="${_csrf.token}">
                <p class="muted">환불 시 사용 포인트 ${numbers.formatInteger(order.pointsUsed)}P는 돌려주고, 적립 포인트 ${numbers.formatInteger(order.earnedPoints)}P는 회수합니다.</p>
                <button class="button button-danger" type="submit">환불 처리</button>
            </form>
            </#if>
        </div>

        <aside class="panel">
            <h2>주문 내역</h2>
            <dl class="summary-list">
                <div><dt>주문번호</dt><dd>${order.orderNumber?html}</dd></div>
                <div><dt>구매자</dt><dd><a class="cell-link" href="/admin/users/${order.buyer.id}">${order.buyer.name?html} (@${order.buyer.username?html})</a></dd></div>
                <div><dt>연락처</dt><dd>${(order.buyer.phone!'-')?html}</dd></div>
                <div><dt>시술</dt><dd><a class="cell-link" href="/admin/procedures/${order.procedureProduct.id}">${order.procedureProduct.name?html}</a></dd></div>
                <div><dt>정상가</dt><dd>${numbers.formatInteger(order.originalAmount)}원</dd></div>
                <div><dt>쿠폰 할인</dt><dd>-${numbers.formatInteger(order.couponDiscount)}원<#if order.coupon??> (${order.coupon.name?html})</#if></dd></div>
                <div><dt>포인트 사용</dt><dd>-${numbers.formatInteger(order.pointsUsed)}P</dd></div>
                <div><dt>적립 포인트</dt><dd>${numbers.formatInteger(order.earnedPoints)}P</dd></div>
                <div><dt>결제 금액</dt><dd><strong>${numbers.formatInteger(order.amount)}원</strong></dd></div>
                <div><dt>결제 수단</dt><dd>${(order.method!'-')?html}</dd></div>
                <div><dt>주문 일시</dt><dd>${temporals.format(order.createdAt, 'yyyy.MM.dd HH:mm')}</dd></div>
                <div><dt>결제 일시</dt><dd><#if order.paidAt??>${temporals.format(order.paidAt, 'yyyy.MM.dd HH:mm')}<#else>-</#if></dd></div>
                <#if order.refundedAt??><div><dt>환불 일시</dt><dd>${temporals.format(order.refundedAt, 'yyyy.MM.dd HH:mm')}</dd></div></#if>
            </dl>
        </aside>
    </section>
</main>
</body>
</html>
