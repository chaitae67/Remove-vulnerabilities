<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>관리자</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<div><#include "/fragments/header.ftl"></div>
<main>
    <section class="page-title">
        <p class="eyebrow">Admin</p>
        <h1>관리자 대시보드</h1>
    </section>
    <#if message??><div class="flash success">${message}</div></#if>
    <section class="content-band admin-grid">
        <div class="panel">
            <h2>시술 상품 일괄 등록 (XML)</h2>
            <form action="/admin/procedures/import" method="post" enctype="multipart/form-data" class="stack-form">
                <input name="file" type="file" accept=".xml" required>
                <button class="button" type="submit">XML 등록</button>
            </form>
        </div>
        <div class="panel">
            <h2>최근 상담 신청</h2>
            <ul class="mini-list">
                <#list consultations as item>
                <li>
                    <strong>${item.name}</strong>
                    <span>${item.phone} · ${item.area} · ${item.preferredContact}</span>
                </li>
                </#list>
            </ul>
        </div>
        <div class="panel">
            <h2>최근 결제</h2>
            <ul class="mini-list">
                <#list orders as order>
                <li>
                    <strong>${order.orderNumber}</strong>
                    <span>${order.buyer.name} · ${order.procedureProduct.name} · ${numbers.formatInteger(order.amount)}원 · ${order.pointsUsed}P 사용</span>
                </li>
                </#list>
            </ul>
        </div>
        <div class="panel">
            <h2>Q&A 답변 관리</h2>
            <ul class="mini-list">
                <#list qnas as post>
                <li>
                    <a href="/qna/${post.id}">${post.title}</a>
                    <span>${post.answered?then('답변완료', '대기')}</span>
                </li>
                </#list>
            </ul>
        </div>
    </section>
</main>
<div><#include "/fragments/footer.ftl"></div>
</body>
</html>
