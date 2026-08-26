<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>공지사항</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<div><#include "/fragments/header.ftl"></div>
<main class="listing-page notice-listing-page">
    <section class="listing-hero with-action">
        <div>
            <p class="eyebrow">Notice</p>
            <h1>공지사항</h1><p>제로데이클리닉의 새로운 소식과 진료 안내를 전해드립니다.</p>
        </div>
        <#if isAdmin><a class="button" href="/notices/new">공지 작성</a></#if>
    </section>
    <#if message??><div class="flash success">${message}</div></#if>
    <section class="listing-content">
        <form action="/notices/search" method="get" class="search-form listing-search">
            <input type="text" name="keyword" value="${keyword!}" placeholder="제목으로 검색">
            <button type="submit" class="button">검색</button>
        </form>
        <ul class="table-list editorial-list notice-editorial-list">
            <#list notices as notice>
            <li>
                <span class="list-index">${notice?index + 1}</span>
                <a class="list-title" href="/notices/${notice.id}">${notice.title}<small>공지 내용을 자세히 확인해 주세요.</small></a>
                <time>${temporals.format(notice.createdAt, 'yyyy.MM.dd')}</time>
            </li>
            </#list>
            <#if notices?size == 0>
            <li>
                <span>검색 결과가 없습니다.</span>
            </li>
            </#if>
        </ul>
    </section>
</main>
<div><#include "/fragments/footer.ftl"></div>
</body>
</html>
