<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>이용 후기</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<div><#include "/fragments/header.ftl"></div>
<main>
    <section class="page-title with-action">
        <div>
            <p class="eyebrow">Review</p>
            <h1>이용 후기</h1>
            <p>실제 이용 고객님들이 남겨주신 솔직한 후기입니다.</p>
        </div>
        <#if isAuthenticated><a class="button" href="/reviews/new">후기 작성</a></#if>
    </section>
    <#if message??><div class="flash success">${message}</div></#if>
    <section class="content-band">
        <form action="/reviews/search" method="get" class="search-form">
            <input type="text" name="keyword" value="${keyword!}" placeholder="제목으로 검색">
            <button type="submit" class="button">검색</button>
        </form>
        <ul class="table-list">
            <#list reviews as review>
            <li>
                <a href="/reviews/${review.id}">${review.title}</a>
                <span>${strings.repeat("★", review.rating)}</span>
                <#if review.procedureProduct??><span class="muted">${review.procedureProduct.name}</span></#if>
                <time>${temporals.format(review.createdAt, 'yyyy.MM.dd')}</time>
            </li>
            </#list>
            <#if reviews?size == 0>
            <li>
                <span>등록된 후기가 없습니다.</span>
            </li>
            </#if>
        </ul>
    </section>
</main>
<div><#include "/fragments/footer.ftl"></div>
</body>
</html>
