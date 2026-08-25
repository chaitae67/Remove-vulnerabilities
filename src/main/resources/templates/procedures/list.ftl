<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>시술 패키지</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<#include "/fragments/header.ftl">
<main>
    <section class="page-title">
        <p class="eyebrow">Procedure</p>
        <h1>시술/상담 패키지</h1>
        <p>실제 수술비가 아닌 로컬 테스트용 예약 결제 상품입니다.</p>
    </section>
    <section class="content-band">
        <form action="/procedures/search" method="get" class="search-form">
            <input type="text" name="keyword" value="${keyword!}" placeholder="패키지명으로 검색">
            <button type="submit" class="button">검색</button>
        </form>
        <div class="product-grid">
            <#list products as row>
            <article class="card product-card">
                <span class="tag">${row[2]}</span>
                <h2>${row[1]}</h2>
                <p>${row[4]}</p>
                <strong>${row[3]?string("#,##0")}원</strong>
                <a class="button" href="/payments/checkout/${row[0]}">결제하기</a>
            </article>
            </#list>
            <#if products?size == 0>
            <p>검색 결과가 없습니다.</p>
            </#if>
        </div>
    </section>
</main>
<#include "/fragments/footer.ftl">
</body>
</html>
