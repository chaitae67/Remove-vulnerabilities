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
<main>
    <section class="page-title with-action">
        <div>
            <p class="eyebrow">Notice</p>
            <h1>공지사항</h1>
        </div>
        <#if isAdmin><a class="button" href="/notices/new">공지 작성</a></#if>
    </section>
    <#if message??><div class="flash success">${message}</div></#if>
    <section class="content-band">
        <form action="/notices/search" method="get" class="search-form">
            <input type="text" name="keyword" value="${keyword!}" placeholder="제목으로 검색">
            <button type="submit" class="button">검색</button>
        </form>
        <ul class="table-list">
            <#list notices as notice>
            <li>
                <a href="/notices/${notice.id}">${notice.title}</a>
                <span>${temporals.format(notice.createdAt, 'yyyy.MM.dd')}</span>
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
