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
            <input name="title" placeholder="제목" required value="<#if formTitle??>${formTitle}<#elseif notice??>${notice.title}</#if>">
            <textarea name="content" rows="12" placeholder="내용" required><#if formContent??>${formContent}<#elseif notice??>${notice.content}</#if></textarea>
            <input name="imageUrl" placeholder="이미지 URL (선택)" value="<#if formImageUrl??>${formImageUrl}<#elseif notice??>${notice.imageUrl!}</#if>">
            <button class="button button-outline" type="submit" formaction="/notices/fetch-image" formnovalidate>이미지 미리보기 불러오기</button>
            <#if previewError??><div class="flash error">${previewError}</div></#if>
            <#if imagePreview??><img src="${imagePreview}" alt="미리보기" style="max-width:100%"></#if>
            <button class="button" type="submit">저장</button>
        </form>
    </section>
</main>
<div><#include "/fragments/footer.ftl"></div>
</body>
</html>
