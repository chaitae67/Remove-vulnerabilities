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
        <p class="muted">${maskedAuthor} · ${temporals.format(notice.createdAt, 'yyyy.MM.dd HH:mm')}</p>
        <#if notice.imageUrl?? && notice.imageUrl?starts_with("/images/")><img src="${notice.imageUrl}" alt="" style="max-width:100%"></#if>
        <div class="article-body">${notice.content}</div>
        <div class="actions">
            <a class="button button-outline" href="/notices">목록</a>
        </div>
    </article>
</main>
<div><#include "/fragments/footer.ftl"></div>
</body>
</html>
