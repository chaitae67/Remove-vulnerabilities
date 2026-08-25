<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${notice.title}</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<div><#include "/fragments/header.ftl"></div>
<main class="narrow-wide">
    <article class="panel article">
        <p class="eyebrow">Notice</p>
        <h1>${notice.title}</h1>
        <p class="muted">${notice.author.name} · ${temporals.format(notice.createdAt, 'yyyy.MM.dd HH:mm')}</p>
        <div class="article-body">${notice.content}</div>
        <div class="actions">
            <a class="button button-outline" href="/notices">목록</a>
            <#if isAdmin>
            <a class="button button-outline" href="/notices/${notice.id}/edit">수정</a>
            <form action="/notices/${notice.id}/delete" method="post">
                <input type="hidden" name="${_csrf.parameterName}" value="${_csrf.token}">
                <button class="button button-danger" type="submit">삭제</button>
            </form>
            </#if>
        </div>
    </article>
</main>
<div><#include "/fragments/footer.ftl"></div>
</body>
</html>
