<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>상담 작성</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<div><#include "/fragments/header.ftl"></div>
<main class="narrow-wide">
    <section class="panel">
        <p class="eyebrow">Q&A Upload</p>
        <h1>상담 작성</h1>
        <form class="stack-form" action="/qna" method="post" enctype="multipart/form-data">
            <input name="title" placeholder="제목" required value="${formTitle!}">
            <input name="phone" placeholder="연락처" value="${formPhone!}">
            <textarea name="content" rows="10" placeholder="상담 내용을 입력해 주세요" required>${formContent!}</textarea>
            <input name="files" type="file" multiple>
            <label class="check"><input type="checkbox" name="privatePost" value="true" <#if formPrivatePost!false>checked</#if>> 비공개 상담으로 등록</label>
            <div class="form-actions">
                <button class="button secondary" type="submit" formaction="/qna/preview" formenctype="application/x-www-form-urlencoded">미리보기</button>
                <button class="button" type="submit">등록하기</button>
            </div>
        </form>
    </section>
    <#if preview?? || previewError??>
    <section class="panel">
        <p class="eyebrow">Q&amp;A Preview</p>
        <h2>${formTitle!}</h2>
        <#if previewError??><div class="flash danger">${previewError}</div></#if>
        <!-- VULNERABLE LAB: 서버 측 템플릿으로 처리된 사용자 입력을 HTML로 출력한다. -->
        <#if preview??><div class="user-content-preview">${preview}</div></#if>
    </section>
    </#if>
</main>
<div><#include "/fragments/footer.ftl"></div>
</body>
</html>
