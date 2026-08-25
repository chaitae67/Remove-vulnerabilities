<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${review.title}</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<div><#include "/fragments/header.ftl"></div>
<main class="narrow-wide">
    <#if message??><div class="flash success">${message}</div></#if>
    <article class="panel article">
        <p class="eyebrow">Review</p>
        <h1>${review.title}</h1>
        <p class="muted">${review.writer.name} · ${temporals.format(review.createdAt, 'yyyy.MM.dd HH:mm')}</p>
        <p>
            <span>${strings.repeat("★", review.rating)}</span>
            <#if review.procedureProduct??><span class="tag">${review.procedureProduct.name}</span></#if>
        </p>
        <div class="article-body">${review.content}</div>
        <#if review.attachments?size gt 0>
        <div class="attachments">
            <h2>첨부 사진</h2>
            <#list review.attachments as file>
            <a href="/uploads/reviews/${file.storedFilename?url}" target="_blank">${file.originalFilename}</a>
            </#list>
        </div>
        </#if>

        <div class="actions">
            <a class="button button-outline" href="/reviews">목록</a>
            <#if canManage>
            <a class="button button-outline" href="/reviews/${review.id}/edit">수정</a>
            <form action="/reviews/${review.id}/delete" method="post">
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
