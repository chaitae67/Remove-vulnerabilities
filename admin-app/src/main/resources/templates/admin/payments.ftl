<#assign navActive = "payments">
<#import "/admin/_macros.ftl" as fmt>
<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>결제 관리 - Zero Day Clinic 관리자</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<#include "/admin/_header.ftl">
<main class="admin-page">
    <section class="page-title">
        <p class="eyebrow">PAYMENTS</p>
        <h1>결제 관리</h1>
        <p>결제 건을 클릭하면 상세 화면에서 금액·예약일을 수정하거나 환불 처리할 수 있습니다.</p>
    </section>

    <section class="content-band">
        <div class="section-head">
            <h2>결제 내역</h2>
            <span class="muted">${orders?size}건</span>
        </div>
        <#if orders?has_content>
        <div class="admin-table-wrap">
            <table class="admin-table">
                <thead>
                <tr>
                    <th scope="col">주문번호</th>
                    <th scope="col">구매자</th>
                    <th scope="col">시술</th>
                    <th scope="col">결제금액</th>
                    <th scope="col">상태</th>
                    <th scope="col">예약일</th>
                    <th scope="col">결제일시</th>
                    <th scope="col"><span class="sr-only">상세</span></th>
                </tr>
                </thead>
                <tbody>
                <#list orders as order>
                <tr data-href="/admin/payments/${order.id}">
                    <td><a class="cell-link" href="/admin/payments/${order.id}">${order.orderNumber?html}</a></td>
                    <td><a class="cell-link" href="/admin/users/${order.buyer.id}">${order.buyer.name?html}</a></td>
                    <td>${order.procedureProduct.name?html}</td>
                    <td><strong>${numbers.formatInteger(order.amount)}원</strong></td>
                    <td><span class="state ${fmt.statusClass(order.status?string)}">${fmt.statusLabel(order.status?string)}</span></td>
                    <td><#if order.reservationDate??><time>${temporals.format(order.reservationDate, 'yyyy.MM.dd')}</time><#else><span class="muted">-</span></#if></td>
                    <td><#if order.paidAt??><time>${temporals.format(order.paidAt, 'yyyy.MM.dd HH:mm')}</time><#else><span class="muted">-</span></#if></td>
                    <td class="cell-action"><a href="/admin/payments/${order.id}">상세 &rsaquo;</a></td>
                </tr>
                </#list>
                </tbody>
            </table>
        </div>
        <#else>
        <div class="empty-state">
            <strong>결제 내역이 없습니다.</strong>
            <p>고객 결제가 발생하면 이곳에 표시됩니다.</p>
        </div>
        </#if>
    </section>
</main>
<script src="/js/admin-rowlink.js"></script>
</body>
</html>
