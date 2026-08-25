<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>공지 작성</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<#include "/fragments/header.ftl">
<main class="narrow-wide">
    <section class="panel">
        <p class="eyebrow">Admin Notice</p>
        <h1><#if notice??>공지 수정<#else>공지 작성</#if></h1>
        <form class="stack-form" <#if notice??>action="/notices/${notice.id}/edit"<#else>action="/notices"</#if> method="post">
            <input name="title" placeholder="제목" required <#if notice??>value="${notice.title}"</#if>>
            <textarea name="content" rows="12" placeholder="내용" required><#if notice??>${notice.content}</#if></textarea>
            <button class="button" type="submit">저장</button>
        </form>
    </section>
</main>
<#include "/fragments/footer.ftl">
</body>
</html>
