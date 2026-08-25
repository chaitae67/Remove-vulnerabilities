<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>공지 작성</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<div><#include "/fragments/header.ftl"></div>
<main class="narrow-wide">
    <section class="panel">
        <p class="eyebrow">Admin Notice</p>
        <h1>${(!notice??)?then('공지 작성', '공지 수정')}</h1>
        <form class="stack-form" action="<#if !notice??>/notices<#else>/notices/${notice.id}/edit</#if>" method="post">
            <input type="hidden" name="${_csrf.parameterName}" value="${_csrf.token}">
            <input name="title" placeholder="제목" required value="<#if notice??>${notice.title}</#if>">
            <textarea name="content" rows="12" placeholder="내용" required><#if notice??>${notice.content}</#if></textarea>
            <button class="button" type="submit">저장</button>
        </form>
    </section>
</main>
<div><#include "/fragments/footer.ftl"></div>
</body>
</html>
