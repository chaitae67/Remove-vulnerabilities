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
            <input type="hidden" name="${_csrf.parameterName}" value="${_csrf.token}">
            <input name="title" placeholder="제목" required value="${formTitle!}">
            <input name="phone" placeholder="연락처" value="${formPhone!}">
            <textarea name="content" rows="10" placeholder="상담 내용을 입력해 주세요" required>${formContent!}</textarea>
            <input id="qna-files" name="files" type="file" multiple>
            <label class="check"><input type="checkbox" name="privatePost" value="true" <#if formPrivatePost!false>checked</#if>> 비공개 상담으로 등록</label>
            <div class="form-actions">
                <button id="qna-preview-button" class="button secondary" type="button">미리보기</button>
                <button class="button" type="submit">등록하기</button>
            </div>
        </form>
    </section>
    <section id="qna-preview-section" class="panel"<#if !(preview?? || previewError??)> hidden</#if>>
        <p class="eyebrow">Q&amp;A Preview</p>
        <h2 id="qna-preview-title">${formTitle!}</h2>
        <#if previewError??><div class="flash danger">${previewError}</div></#if>
        <div id="qna-preview-content" class="user-content-preview"><#if preview??>${preview}</#if></div>
        <div id="qna-preview-images" class="review-preview-images"></div>
        <div id="qna-preview-files" class="attachments"></div>
    </section>
</main>
<div><#include "/fragments/footer.ftl"></div>
<script>
(() => {
    const form = document.querySelector('form[action="/qna"]');
    const button = document.getElementById('qna-preview-button');
    const files = document.getElementById('qna-files');
    const section = document.getElementById('qna-preview-section');
    const titlePreview = document.getElementById('qna-preview-title');
    const contentPreview = document.getElementById('qna-preview-content');
    const imagePreview = document.getElementById('qna-preview-images');
    const filePreview = document.getElementById('qna-preview-files');
    let objectUrls = [];

    button.addEventListener('click', () => {
        if (!form.reportValidity()) {
            return;
        }

        titlePreview.textContent = form.elements.title.value;
        contentPreview.textContent = form.elements.content.value;
        objectUrls.forEach(URL.revokeObjectURL);
        objectUrls = [];
        imagePreview.replaceChildren();
        filePreview.replaceChildren();

        Array.from(files.files).forEach(file => {
            if (file.type.startsWith('image/')) {
                const url = URL.createObjectURL(file);
                objectUrls.push(url);
                const image = document.createElement('img');
                image.src = url;
                image.alt = file.name;
                imagePreview.appendChild(image);
            }
            const name = document.createElement('span');
            name.textContent = file.name;
            filePreview.appendChild(name);
        });

        section.hidden = false;
        section.scrollIntoView({behavior: 'smooth', block: 'start'});
    });
})();
</script>
</body>
</html>
