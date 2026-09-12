<#assign navActive = "coupons">
<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>쿠폰 관리 - Zero Day Clinic 관리자</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<#include "/admin/_header.ftl">
<main class="admin-page">
    <section class="page-title">
        <p class="eyebrow">COUPONS</p>
        <h1>이벤트 쿠폰 관리</h1>
        <p>이벤트 쿠폰을 발급하고 발급 현황을 확인합니다.</p>
    </section>

    <section class="content-band admin-detail-grid">
        <div class="panel">
            <h2>쿠폰 발급</h2>
            <#-- (실습용) 발급 요청을 GET 으로 보내는 폼. CSRF 토큰이 없다. -->
            <form action="/admin/coupons/issue" method="get" class="stack-form">
                <label>쿠폰 코드<input name="code" placeholder="EVENT2026" required></label>
                <label>쿠폰명<input name="name" value="이벤트 쿠폰"></label>
                <label>할인 금액 (원)<input name="discountAmount" type="number" value="10000"></label>
                <label>만료일<input name="expiresAt" type="date"></label>
                <div class="form-actions">
                    <button class="button" type="submit">쿠폰 발급</button>
                </div>
            </form>
        </div>

        <aside class="panel">
            <div class="section-head">
                <h2>발급된 쿠폰</h2>
                <span class="muted">${coupons?size}건</span>
            </div>
            <#if coupons?has_content>
            <div class="admin-table-wrap">
                <table class="admin-table">
                    <thead>
                    <tr>
                        <th scope="col">코드</th>
                        <th scope="col">쿠폰명</th>
                        <th scope="col">할인액</th>
                        <th scope="col">상태</th>
                        <th scope="col">만료일</th>
                    </tr>
                    </thead>
                    <tbody>
                    <#list coupons as coupon>
                    <tr>
                        <td><strong>${coupon.code?html}</strong></td>
                        <td>${coupon.name?html}</td>
                        <td>${numbers.formatInteger(coupon.discountAmount)}원</td>
                        <td><span class="state <#if coupon.active>status-paid<#else>status-canceled</#if>">${coupon.active?then('활성', '중지')}</span></td>
                        <td><#if coupon.expiresAt??><time>${temporals.format(coupon.expiresAt, 'yyyy.MM.dd')}</time><#else><span class="muted">-</span></#if></td>
                    </tr>
                    </#list>
                    </tbody>
                </table>
            </div>
            <#else>
            <p class="muted">발급된 쿠폰이 없습니다.</p>
            </#if>
        </aside>
    </section>
</main>
</body>
</html>
