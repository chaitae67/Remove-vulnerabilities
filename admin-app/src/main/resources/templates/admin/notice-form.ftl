<#assign navActive = "notices">
<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title><#if formMode == 'create'>공지 작성<#else>공지 수정</#if> - Zero Day Clinic 관리자</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<#include "/admin/_header.ftl">
<main class="admin-page admin-detail">
    <section class="page-title">
        <p class="eyebrow">NOTICE</p>
        <h1><#if formMode == 'create'>공지사항 작성<#else>공지사항 수정</#if></h1>
        <p><a class="back-link" href="/admin/notices">← 공지사항 목록</a></p>
    </section>
    <section class="content-band admin-detail-grid">
        <div class="panel">
            <form action="<#if formMode == 'create'>/admin/notices<#else>/admin/notices/${notice.id?c}</#if>" method="post" class="stack-form">
                <input type="hidden" name="${_csrf.parameterName}" value="${_csrf.token}">
                <label>제목<input name="title" maxlength="160" value="<#if notice??>${notice.title?html}</#if>" required></label>
                <label>내용<textarea name="content" rows="14" maxlength="4000" required><#if notice??>${notice.content?html}</#if></textarea></label>
                <label>이미지 경로<input name="imageUrl" maxlength="500" placeholder="/images/example.jpg" value="<#if notice?? && notice.imageUrl??>${notice.imageUrl?html}</#if>"></label>
                <label>관리자 비밀번호 재확인<input name="adminPassword" type="password" autocomplete="current-password" required></label>
                <button class="button" type="submit"><#if formMode == 'create'>등록<#else>수정</#if></button>
            </form>
        </div>
        <#if formMode == 'edit'>
        <div class="panel danger-zone">
            <h2>공지 삭제</h2><p>삭제한 공지는 복구할 수 없습니다.</p>
            <form action="/admin/notices/${notice.id?c}/delete" method="post" class="danger-form" onsubmit="return confirm('이 공지사항을 삭제하시겠습니까?');">
                <input type="hidden" name="${_csrf.parameterName}" value="${_csrf.token}">
                <label>관리자 비밀번호 재확인<input name="adminPassword" type="password" autocomplete="current-password" required></label>
                <button class="button button-danger" type="submit">삭제</button>
            </form>
        </div>
        </#if>
    </section>
</main>
</body>
</html>
