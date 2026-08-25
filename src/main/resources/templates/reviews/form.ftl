<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title><#if review??>후기 수정<#else>후기 작성</#if></title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<#include "/fragments/header.ftl">
<main class="narrow-wide">
    <section class="panel">
        <p class="eyebrow">Review</p>
        <h1><#if review??>후기 수정<#else>후기 작성</#if></h1>
        <form class="stack-form" <#if review??>action="/reviews/${review.id}/edit"<#else>action="/reviews"</#if> method="post" enctype="multipart/form-data">
            <#if !(review??)>
            <input type="hidden" name="writerId" value="${currentUserId}">
            </#if>
            <input name="title" placeholder="제목" required <#if formTitle??>value="${formTitle}"<#elseif review??>value="${review.title}"</#if>>
            <select name="procedureProductId">
                <option value="">시술 선택 안 함</option>
                <#list products as product>
                <option value="${product.id}" <#if formProcedureProductId?? && formProcedureProductId == product.id>selected="selected"<#elseif review?? && review.procedureProduct?? && review.procedureProduct.id == product.id>selected="selected"</#if>>${product.name}</option>
                </#list>
            </select>
            <select name="rating" required>
                <option value="">평점 선택</option>
                <#list [5,4,3,2,1] as score>
                <option value="${score}" <#if formRating?? && formRating == score>selected="selected"<#elseif review?? && review.rating == score>selected="selected"</#if>><#list 1..score as i>★</#list></option>
                </#list>
            </select>
            <textarea name="content" rows="10" placeholder="시술 경험을 자세히 남겨주세요" required><#if formContent??>${formContent}<#elseif review??>${review.content}</#if></textarea>
            <label class="check">사진 첨부 (이미지 파일만 업로드 가능)</label>
            <input name="photos" type="file" accept="image/*" multiple>
            <#if review?? && review.attachments?size > 0>
            <div class="attachments">
                <#list review.attachments as file>
                <span>${file.originalFilename}</span>
                </#list>
            </div>
            </#if>
            <div class="form-actions">
                <#if !(review??)>
                <button class="button secondary" type="submit" formaction="/reviews/preview" formenctype="application/x-www-form-urlencoded">카드 미리보기</button>
                </#if>
                <button class="button" type="submit">저장</button>
            </div>
        </form>
    </section>
    <#if preview?? || previewError??>
    <section class="panel">
        <p class="eyebrow">Review Card Preview</p>
        <article class="review-preview-card">
            <div class="review-preview-head">
                <h2>${formTitle!}</h2>
                <span class="state"><#if formRating??><#list 1..formRating as i>★</#list></#if></span>
            </div>
            <#if previewError??>
            <div class="flash danger">${previewError}</div>
            </#if>
            <#if preview??>
            <div class="user-content-preview">${preview}</div>
            </#if>
        </article>
    </section>
    </#if>
</main>
<#include "/fragments/footer.ftl">
</body>
</html>
