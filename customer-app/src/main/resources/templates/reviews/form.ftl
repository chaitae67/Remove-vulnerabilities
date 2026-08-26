<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${(!review??)?then('후기 작성', '후기 수정')}</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<div><#include "/fragments/header.ftl"></div>
<main class="narrow-wide">
    <section class="panel">
        <p class="eyebrow">Review</p>
        <h1>${(!review??)?then('후기 작성', '후기 수정')}</h1>
        <form id="review-form" class="stack-form" action="<#if !review??>/reviews<#else>/reviews/${review.id}/edit</#if>" method="post" enctype="multipart/form-data">
            <input type="hidden" name="${_csrf.parameterName}" value="${_csrf.token}">
            <#if !review??><input type="hidden" name="writerId" value="${currentUserId}"></#if>
            <input name="title" placeholder="제목" required value="<#if formTitle??>${formTitle}<#elseif review??>${review.title}</#if>">
            <select name="procedureProductId">
                <option value="">시술 선택 안 함</option>
                <#list products as product>
                <option value="${product.id}"<#if (formProcedureProductId?? && formProcedureProductId == product.id) || (!formProcedureProductId?? && review?? && review.procedureProduct?? && review.procedureProduct.id == product.id)> selected</#if>>${product.name}</option>
                </#list>
            </select>
            <select name="rating" required>
                <option value="">평점 선택</option>
                <#list 5..1 as score>
                <option value="${score}"<#if (formRating?? && formRating == score) || (!formRating?? && review?? && review.rating == score)> selected</#if>>${strings.repeat("★", score)}</option>
                </#list>
            </select>
            <textarea name="content" rows="10" placeholder="시술 경험을 자세히 남겨주세요" required><#if formContent??>${formContent}<#elseif review??>${review.content}</#if></textarea>
            <label class="check">사진 첨부 (이미지 파일만 업로드 가능)</label>
            <input id="review-photos" name="photos" type="file" accept="image/png,image/jpeg,image/webp,image/gif" multiple>
            <#if review?? && (review.attachments?size gt 0)>
            <div class="attachments">
                <#list review.attachments as file>
                <span>${file.originalFilename}</span>
                </#list>
            </div>
            </#if>
            <div class="form-actions">
                <#if !review??><button id="review-preview-button" class="button secondary" type="button">카드 미리보기</button></#if>
                <button class="button" type="submit">저장</button>
            </div>
        </form>
    </section>
    <#if !review??><section id="review-preview-section" class="panel"<#if !(preview?? || previewError??)> hidden</#if>>
        <p class="eyebrow">Review Card Preview</p>
        <article class="review-preview-card">
            <div class="review-preview-head">
                <h2 id="review-preview-title">${formTitle!}</h2>
                <span id="review-preview-rating" class="state">${strings.repeat("★", formRating!0)}</span>
            </div>
            <#if previewError??><div class="flash danger">${previewError}</div></#if>
            <!-- VULNERABLE LAB: 서버 측 템플릿으로 처리된 사용자 입력을 HTML로 출력한다. -->
            <div id="review-preview-content" class="user-content-preview"><#if preview??>${preview}</#if></div>
            <div id="review-preview-images" class="review-preview-images"></div>
        </article>
    </section>
    </#if>
</main>
<div><#include "/fragments/footer.ftl"></div>
<#if !review??><script>
(() => {
    const form = document.getElementById('review-form');
    const button = document.getElementById('review-preview-button');
    const photos = document.getElementById('review-photos');
    const section = document.getElementById('review-preview-section');
    const titlePreview = document.getElementById('review-preview-title');
    const ratingPreview = document.getElementById('review-preview-rating');
    const contentPreview = document.getElementById('review-preview-content');
    const imagePreview = document.getElementById('review-preview-images');
    let objectUrls = [];

    button.addEventListener('click', () => {
        const title = form.elements.title;
        const rating = form.elements.rating;
        const content = form.elements.content;
        if (!title.value.trim() || !rating.value || !content.value.trim()) {
            form.reportValidity();
            return;
        }

        titlePreview.textContent = title.value;
        ratingPreview.textContent = '★'.repeat(Number(rating.value));
        contentPreview.textContent = content.value;
        objectUrls.forEach(URL.revokeObjectURL);
        objectUrls = [];
        imagePreview.replaceChildren();

        Array.from(photos.files).filter(file =>
            file.type.startsWith('image/') || /\.(png|jpe?g|webp|gif)$/i.test(file.name)
        ).forEach(file => {
            const url = URL.createObjectURL(file);
            objectUrls.push(url);
            const image = document.createElement('img');
            image.src = url;
            image.alt = file.name;
            imagePreview.appendChild(image);
        });

        section.hidden = false;
        section.scrollIntoView({behavior: 'smooth', block: 'start'});
    });
})();
</script></#if>
</body>
</html>
